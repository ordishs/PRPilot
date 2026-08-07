import Foundation
import PRPilotModels
import CommandSupport

public struct GitHubClient: Sendable {
    private let runner: CommandRunner
    private let ghPath: String

    public init(runner: CommandRunner, ghPath: String) {
        self.runner = runner
        self.ghPath = ghPath
    }

    public func fetchReview(for ref: PRLocator, origin: ReviewOrigin = .added, now: Date = Date()) async throws -> WorkItem {
        let coreFields = "number,title,url,state,isDraft,author,headRefName,baseRefName"
        var result = try await runner.run(
            executable: ghPath,
            arguments: prViewArguments(ref: ref, fields: coreFields + ",closingIssuesReferences")
        )
        if result.exitCode != 0, result.standardError.contains("Unknown JSON field") {
            // Older gh (< the release that added closingIssuesReferences) rejects the
            // field. It only feeds the cosmetic closingIssueNumber, so retry without it.
            result = try await runner.run(
                executable: ghPath,
                arguments: prViewArguments(ref: ref, fields: coreFields)
            )
        }
        guard result.exitCode == 0 else {
            throw GitHubError.commandFailed(exitCode: result.exitCode, message: result.standardError)
        }
        let pullRequest: GHPullRequest
        do {
            pullRequest = try JSONDecoder().decode(GHPullRequest.self, from: Data(result.standardOutput.utf8))
        } catch {
            throw GitHubError.decodingFailed(String(describing: error))
        }
        guard let url = URL(string: pullRequest.url) else {
            throw GitHubError.decodingFailed("invalid url: \(pullRequest.url)")
        }
        let closingIssueNumber = pullRequest.closingIssuesReferences.first?.number
        return WorkItem(
            title: pullRequest.title,
            repoKey: "github.com/\(ref.owner)/\(ref.repo)",
            baseBranch: pullRequest.baseRefName,
            headBranch: pullRequest.headRefName,
            prRef: PRRef(
                owner: ref.owner,
                repo: ref.repo,
                number: pullRequest.number,
                url: url,
                authorLogin: pullRequest.author.login
            ),
            prState: GitHubClient.mapState(state: pullRequest.state, isDraft: pullRequest.isDraft),
            origin: origin,
            closingIssueNumber: closingIssueNumber,
            addedAt: now
        )
    }

    private func prViewArguments(ref: PRLocator, fields: String) -> [String] {
        ["pr", "view", String(ref.number), "--repo", "\(ref.owner)/\(ref.repo)", "--json", fields]
    }

    static func mapState(state: String, isDraft: Bool) -> PRState {
        if state == "MERGED" {
            return .merged
        }
        if state == "CLOSED" {
            return .closed
        }
        if isDraft {
            return .draft
        }
        return .open
    }

    public func fetchCurrentLogin() async throws -> String {
        let result = try await runner.run(executable: ghPath, arguments: ["api", "user", "--jq", ".login"])
        guard result.exitCode == 0 else {
            throw GitHubError.commandFailed(exitCode: result.exitCode, message: result.standardError)
        }
        let login = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !login.isEmpty else {
            throw GitHubError.decodingFailed("empty login from gh api user")
        }
        return login
    }

    public func fetchDefaultBase(owner: String, repo: String) async throws -> String {
        let view = try await fetchRepoView(owner: owner, repo: repo)
        if view.isFork, let parent = view.parent,
           let parentView = try? await fetchRepoView(owner: parent.owner.login, repo: parent.name),
           let parentBranch = parentView.defaultBranchRef?.name {
            return parentBranch
        }
        return view.defaultBranchRef?.name ?? "main"
    }

    private func fetchRepoView(owner: String, repo: String) async throws -> GHRepoView {
        let result = try await runner.run(
            executable: ghPath,
            arguments: ["repo", "view", "\(owner)/\(repo)", "--json", "isFork,parent,defaultBranchRef"]
        )
        guard result.exitCode == 0 else {
            throw GitHubError.commandFailed(exitCode: result.exitCode, message: result.standardError)
        }
        do {
            return try JSONDecoder().decode(GHRepoView.self, from: Data(result.standardOutput.utf8))
        } catch {
            throw GitHubError.decodingFailed(String(describing: error))
        }
    }

    public struct PRSnapshot: Sendable, Equatable {
        public let prState: PRState
        public let approvedByMe: Bool
        public let status: PRStatus
        public init(prState: PRState, approvedByMe: Bool, status: PRStatus) {
            self.prState = prState
            self.approvedByMe = approvedByMe
            self.status = status
        }
    }

    /// Everything the per-item refresh needs, in one GraphQL call: PR state, whether you
    /// approved it, CI/behind/readiness, and whether the author has moved since your last
    /// review. Replaced two `gh pr view` calls, halving poll traffic.
    public func fetchPRSnapshot(for ref: PRLocator, login: String) async throws -> PRSnapshot {
        let result = try await runner.run(
            executable: ghPath,
            arguments: [
                "api", "graphql",
                "-f", "owner=\(ref.owner)",
                "-f", "repo=\(ref.repo)",
                "-F", "number=\(ref.number)",
                "-f", "query=\(Self.snapshotQuery)",
            ]
        )
        guard result.exitCode == 0 else {
            throw GitHubError.commandFailed(exitCode: result.exitCode, message: result.standardError)
        }
        let payload: GHSnapshotResponse
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            payload = try decoder.decode(GHSnapshotResponse.self, from: Data(result.standardOutput.utf8))
        } catch {
            throw GitHubError.decodingFailed(String(describing: error))
        }
        let pr = payload.data.repository.pullRequest
        let headCommit = pr.commits.nodes.first?.commit

        let myReviews = pr.reviews.nodes.filter { $0.author?.login == login }
        let decisive = myReviews.filter { ["APPROVED", "CHANGES_REQUESTED", "DISMISSED"].contains($0.state) }
        let approvedByMe = decisive.last?.state == "APPROVED"

        let threads = pr.reviewThreads.nodes.map { node in
            ReviewThreadSnapshot(
                isResolved: node.isResolved,
                resolvedByLogin: node.resolvedBy?.login,
                comments: node.comments.nodes.compactMap { comment in
                    guard let login = comment.author?.login else { return nil }
                    return ThreadComment(authorLogin: login, createdAt: comment.createdAt)
                }
            )
        }
        let authorUpdatedAt = AuthorUpdate.latestUpdate(
            myLogin: login,
            authorLogin: pr.author?.login ?? "",
            myReviewDates: myReviews.compactMap(\.submittedAt),
            threads: threads,
            headCommittedAt: headCommit?.committedDate,
            reviewRequestedFromMeAt: pr.timelineItems.nodes
                .filter { $0.requestedReviewer?.login == login }
                .compactMap(\.createdAt)
        )

        return PRSnapshot(
            prState: GitHubClient.mapState(state: pr.state, isDraft: pr.isDraft),
            approvedByMe: approvedByMe,
            status: PRStatus(
                ci: Self.aggregateCI(rollup: headCommit?.statusCheckRollup),
                isBehind: pr.mergeStateStatus == "BEHIND",
                readiness: PRStatus.readiness(isDraft: pr.isDraft, reviewDecision: pr.reviewDecision),
                authorUpdatedAt: authorUpdatedAt
            )
        )
    }

    /// `contexts` is paginated at 100. Within that, aggregate the individual checks exactly
    /// as before; beyond it an unfetched check could hide a failure, so defer to the
    /// rollup's own state rather than report a wrong answer confidently.
    static func aggregateCI(rollup: GHSnapshotResponse.StatusCheckRollup?) -> CIStatus {
        guard let rollup else { return .none }
        let contexts = rollup.contexts
        if contexts.totalCount > contexts.nodes.count {
            switch rollup.state?.uppercased() {
            case "SUCCESS": return .passing
            case "FAILURE", "ERROR": return .failing
            case "PENDING", "EXPECTED": return .pending
            default: return .none
            }
        }
        return PRStatus.aggregateCI(contexts.nodes.map {
            CICheck(status: $0.status, conclusion: $0.conclusion, state: $0.state)
        })
    }

    private static let snapshotQuery = """
    query($owner:String!,$repo:String!,$number:Int!){
      repository(owner:$owner,name:$repo){ pullRequest(number:$number){
        state isDraft reviewDecision mergeStateStatus
        author{login}
        commits(last:1){nodes{commit{ committedDate
          statusCheckRollup{ state contexts(first:100){ totalCount nodes{
            __typename
            ... on CheckRun{ status conclusion }
            ... on StatusContext{ state }
          }}}
        }}}
        reviews(first:100){nodes{author{login} state submittedAt}}
        reviewThreads(first:100){nodes{
          isResolved resolvedBy{login}
          comments(first:50){nodes{author{login} createdAt}}
        }}
        timelineItems(first:100, itemTypes:[REVIEW_REQUESTED_EVENT]){nodes{
          ... on ReviewRequestedEvent{ createdAt requestedReviewer{ ... on User{login} } }
        }}
      }}
    }
    """
}

public struct IssueHit: Sendable, Equatable {
    public let owner: String
    public let repo: String
    public let number: Int
    public let title: String
    public let url: String
    public let authorLogin: String
    public let state: String

    public var id: String { "\(owner)/\(repo)/issues/\(number)" }
    public var locator: IssueLocator { IssueLocator(owner: owner, repo: repo, number: number) }

    public init(owner: String, repo: String, number: Int, title: String, url: String, authorLogin: String, state: String) {
        self.owner = owner
        self.repo = repo
        self.number = number
        self.title = title
        self.url = url
        self.authorLogin = authorLogin
        self.state = state
    }
}

public struct DiscoveryHit: Sendable, Equatable {
    public let owner: String
    public let repo: String
    public let number: Int
    public let title: String
    public let url: String
    public let authorLogin: String
    public let state: String
    public let isDraft: Bool

    public var id: String { "\(owner)/\(repo)#\(number)" }
    public var ref: PRLocator { PRLocator(owner: owner, repo: repo, number: number) }

    public init(owner: String, repo: String, number: Int, title: String, url: String, authorLogin: String, state: String, isDraft: Bool) {
        self.owner = owner
        self.repo = repo
        self.number = number
        self.title = title
        self.url = url
        self.authorLogin = authorLogin
        self.state = state
        self.isDraft = isDraft
    }
}

private struct GHSearchHit: Decodable {
    struct Author: Decodable { let login: String }
    struct Repository: Decodable { let nameWithOwner: String }
    let number: Int
    let title: String
    let url: String
    let state: String
    let isDraft: Bool
    let author: Author
    let repository: Repository
}

struct GHIssue: Decodable {
    struct Author: Decodable { let login: String }
    let number: Int
    let title: String
    let url: String
    let state: String
    let author: Author
}

private struct GHIssueSearchHit: Decodable {
    struct Author: Decodable { let login: String }
    struct Repository: Decodable { let nameWithOwner: String }
    let number: Int
    let title: String
    let url: String
    let state: String
    let author: Author
    let repository: Repository
}

extension GitHubClient {
    public func searchPRs(query: String) async throws -> [DiscoveryHit] {
        let fields = "number,title,url,state,isDraft,author,repository"
        let queryTokens = query.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        let result = try await runner.run(
            executable: ghPath,
            arguments: ["search", "prs"] + queryTokens + ["--json", fields, "--limit", "100"]
        )
        guard result.exitCode == 0 else {
            throw GitHubError.commandFailed(exitCode: result.exitCode, message: result.standardError)
        }
        let raw: [GHSearchHit]
        do {
            raw = try JSONDecoder().decode([GHSearchHit].self, from: Data(result.standardOutput.utf8))
        } catch {
            throw GitHubError.decodingFailed(String(describing: error))
        }
        return raw.compactMap { row -> DiscoveryHit? in
            let parts = row.repository.nameWithOwner.split(separator: "/", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return nil }
            return DiscoveryHit(
                owner: parts[0],
                repo: parts[1],
                number: row.number,
                title: row.title,
                url: row.url,
                authorLogin: row.author.login,
                state: row.state,
                isDraft: row.isDraft
            )
        }
    }

    public static func mapDiscoveryState(state: String, isDraft: Bool) -> PRState {
        mapState(state: state.uppercased(), isDraft: isDraft)
    }
}

extension GitHubClient {
    public static func mapIssueState(state: String) -> PRState {
        state.uppercased() == "CLOSED" ? .closed : .open
    }

    public func searchIssues(query: String) async throws -> [IssueHit] {
        let fields = "number,title,url,state,author,repository"
        var tokens = query.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        if !tokens.contains("is:issue") {
            tokens.append("is:issue")
        }
        let result = try await runner.run(
            executable: ghPath,
            arguments: ["search", "issues"] + tokens + ["--json", fields, "--limit", "100"]
        )
        guard result.exitCode == 0 else {
            throw GitHubError.commandFailed(exitCode: result.exitCode, message: result.standardError)
        }
        let raw: [GHIssueSearchHit]
        do {
            raw = try JSONDecoder().decode([GHIssueSearchHit].self, from: Data(result.standardOutput.utf8))
        } catch {
            throw GitHubError.decodingFailed(String(describing: error))
        }
        return raw.compactMap { row -> IssueHit? in
            let parts = row.repository.nameWithOwner.split(separator: "/", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return nil }
            return IssueHit(
                owner: parts[0], repo: parts[1], number: row.number, title: row.title,
                url: row.url, authorLogin: row.author.login, state: row.state
            )
        }
    }

    public func fetchIssue(for loc: IssueLocator, origin: ReviewOrigin = .added, now: Date = Date()) async throws -> WorkItem {
        let result = try await runner.run(
            executable: ghPath,
            arguments: ["issue", "view", String(loc.number), "--repo", "\(loc.owner)/\(loc.repo)", "--json", "number,title,url,state,author"]
        )
        guard result.exitCode == 0 else {
            throw GitHubError.commandFailed(exitCode: result.exitCode, message: result.standardError)
        }
        let issue: GHIssue
        do {
            issue = try JSONDecoder().decode(GHIssue.self, from: Data(result.standardOutput.utf8))
        } catch {
            throw GitHubError.decodingFailed(String(describing: error))
        }
        guard let url = URL(string: issue.url) else {
            throw GitHubError.decodingFailed("invalid url: \(issue.url)")
        }
        let base = (try? await fetchDefaultBase(owner: loc.owner, repo: loc.repo)) ?? "main"
        return WorkItem(
            title: issue.title,
            repoKey: "github.com/\(loc.owner)/\(loc.repo)",
            baseBranch: base,
            headBranch: WorkItem.issueBranchName(number: issue.number, title: issue.title),
            issueRef: IssueRef(
                owner: loc.owner, repo: loc.repo, number: issue.number,
                url: url, authorLogin: issue.author.login
            ),
            prState: GitHubClient.mapIssueState(state: issue.state),
            origin: origin,
            addedAt: now
        )
    }
}

struct GHRepoView: Decodable {
    struct Ref: Decodable { let name: String }
    struct Parent: Decodable {
        struct Owner: Decodable { let login: String }
        let name: String
        let owner: Owner
    }
    let isFork: Bool
    let parent: Parent?
    let defaultBranchRef: Ref?
}

struct GHSnapshotResponse: Decodable {
    /// `login` is optional because an inline fragment that does not match yields an empty
    /// object rather than null — a team review request decodes as `{}`.
    struct Login: Decodable { let login: String? }

    struct Context: Decodable {
        let status: String?
        let conclusion: String?
        let state: String?
    }
    struct Contexts: Decodable {
        let totalCount: Int
        let nodes: [Context]
    }
    struct StatusCheckRollup: Decodable {
        let state: String?
        let contexts: Contexts
    }
    struct Commit: Decodable {
        let committedDate: Date?
        let statusCheckRollup: StatusCheckRollup?
    }
    struct CommitNode: Decodable { let commit: Commit }
    struct Commits: Decodable { let nodes: [CommitNode] }

    struct Review: Decodable {
        let author: Login?   // null for reviews by deleted accounts
        let state: String
        let submittedAt: Date?
    }
    struct Reviews: Decodable { let nodes: [Review] }

    struct Comment: Decodable {
        let author: Login?
        let createdAt: Date
    }
    struct Comments: Decodable { let nodes: [Comment] }
    struct ReviewThread: Decodable {
        let isResolved: Bool
        let resolvedBy: Login?
        let comments: Comments
    }
    struct ReviewThreads: Decodable { let nodes: [ReviewThread] }

    struct TimelineItem: Decodable {
        let createdAt: Date?
        let requestedReviewer: Login?   // absent when the reviewer is a team
    }
    struct TimelineItems: Decodable { let nodes: [TimelineItem] }

    struct PullRequest: Decodable {
        let state: String
        let isDraft: Bool
        let reviewDecision: String?
        let mergeStateStatus: String?
        let author: Login?
        let commits: Commits
        let reviews: Reviews
        let reviewThreads: ReviewThreads
        let timelineItems: TimelineItems
    }
    struct Repository: Decodable { let pullRequest: PullRequest }
    struct DataPayload: Decodable { let repository: Repository }
    let data: DataPayload
}

struct GHPullRequest: Decodable {
    struct Author: Decodable {
        let login: String
    }

    struct ClosingIssueRef: Decodable {
        let number: Int
    }

    private enum CodingKeys: String, CodingKey {
        case number, title, url, state, isDraft, author, headRefName, baseRefName, closingIssuesReferences
    }

    let number: Int
    let title: String
    let url: String
    let state: String
    let isDraft: Bool
    let author: Author
    let headRefName: String
    let baseRefName: String
    let closingIssuesReferences: [ClosingIssueRef]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        number = try container.decode(Int.self, forKey: .number)
        title = try container.decode(String.self, forKey: .title)
        url = try container.decode(String.self, forKey: .url)
        state = try container.decode(String.self, forKey: .state)
        isDraft = try container.decode(Bool.self, forKey: .isDraft)
        author = try container.decode(Author.self, forKey: .author)
        headRefName = try container.decode(String.self, forKey: .headRefName)
        baseRefName = try container.decode(String.self, forKey: .baseRefName)
        closingIssuesReferences = try container.decodeIfPresent([ClosingIssueRef].self, forKey: .closingIssuesReferences) ?? []
    }
}
