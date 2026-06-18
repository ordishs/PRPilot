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

    public struct ReviewState: Sendable, Equatable {
        public let approvedByMe: Bool
        public let prState: PRState
        public init(approvedByMe: Bool, prState: PRState) {
            self.approvedByMe = approvedByMe
            self.prState = prState
        }
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

    public func fetchReviewState(for ref: PRLocator, login: String) async throws -> ReviewState {
        let result = try await runner.run(
            executable: ghPath,
            arguments: prViewArguments(ref: ref, fields: "state,isDraft,reviews")
        )
        guard result.exitCode == 0 else {
            throw GitHubError.commandFailed(exitCode: result.exitCode, message: result.standardError)
        }
        let payload: GHReviewStatePayload
        do {
            payload = try JSONDecoder().decode(GHReviewStatePayload.self, from: Data(result.standardOutput.utf8))
        } catch {
            throw GitHubError.decodingFailed(String(describing: error))
        }
        let decisive = payload.reviews.filter {
            $0.author?.login == login && ["APPROVED", "CHANGES_REQUESTED", "DISMISSED"].contains($0.state)
        }
        let approvedByMe = decisive.last?.state == "APPROVED"
        return ReviewState(
            approvedByMe: approvedByMe,
            prState: GitHubClient.mapState(state: payload.state, isDraft: payload.isDraft)
        )
    }

    public func fetchPRStatus(for ref: PRLocator) async throws -> PRStatus {
        let result = try await runner.run(
            executable: ghPath,
            arguments: prViewArguments(ref: ref, fields: "statusCheckRollup,mergeStateStatus,isDraft,reviewDecision")
        )
        guard result.exitCode == 0 else {
            throw GitHubError.commandFailed(exitCode: result.exitCode, message: result.standardError)
        }
        let payload: GHStatusPayload
        do {
            payload = try JSONDecoder().decode(GHStatusPayload.self, from: Data(result.standardOutput.utf8))
        } catch {
            throw GitHubError.decodingFailed(String(describing: error))
        }
        let checks = (payload.statusCheckRollup ?? []).map {
            CICheck(status: $0.status, conclusion: $0.conclusion, state: $0.state)
        }
        return PRStatus(
            ci: PRStatus.aggregateCI(checks),
            isBehind: payload.mergeStateStatus == "BEHIND",
            readiness: PRStatus.readiness(isDraft: payload.isDraft, reviewDecision: payload.reviewDecision)
        )
    }
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

struct GHStatusPayload: Decodable {
    struct Check: Decodable {
        let status: String?
        let conclusion: String?
        let state: String?
    }
    let statusCheckRollup: [Check]?
    let mergeStateStatus: String?
    let isDraft: Bool
    let reviewDecision: String?
}

struct GHReviewStatePayload: Decodable {
    struct Review: Decodable {
        struct Author: Decodable { let login: String }
        let author: Author?  // null for reviews by deleted accounts
        let state: String
    }
    let state: String
    let isDraft: Bool
    let reviews: [Review]
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
