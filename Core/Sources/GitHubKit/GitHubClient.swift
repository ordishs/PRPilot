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

    /// What the base branch demands before it merges. One call per repository and branch,
    /// not per pull request — the caller caches it.
    ///
    /// `rules/branches/{branch}` reports the rulesets that apply to the branch. It answers
    /// for anyone who can read the repository, unlike the GraphQL `branchProtectionRule`,
    /// which needs push access and reports nothing at all for a ruleset.
    public func fetchMergeRules(owner: String, repo: String, branch: String) async throws -> MergeRules {
        let result = try await runner.run(
            executable: ghPath,
            arguments: ["api", "repos/\(owner)/\(repo)/rules/branches/\(branch)"]
        )
        guard result.exitCode == 0 else {
            throw GitHubError.commandFailed(exitCode: result.exitCode, message: result.standardError)
        }
        let rules: [GHBranchRule]
        do {
            rules = try JSONDecoder().decode([GHBranchRule].self, from: Data(result.standardOutput.utf8))
        } catch {
            throw GitHubError.decodingFailed(String(describing: error))
        }
        // A rule that demands zero approvals demands nothing, so it reads as unknown and
        // the row shows a plain count rather than a "0/0" that means nothing.
        let required = rules
            .first { $0.type == "pull_request" }?
            .parameters?
            .requiredApprovingReviewCount
        return MergeRules(requiredApprovals: (required ?? 0) > 0 ? required : nil)
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
        public let myReviewState: MyReviewState
        public let myLastReviewAt: Date?
        public let status: PRStatus

        public init(
            prState: PRState,
            approvedByMe: Bool,
            myReviewState: MyReviewState = .none,
            myLastReviewAt: Date? = nil,
            status: PRStatus
        ) {
            self.prState = prState
            self.approvedByMe = approvedByMe
            self.myReviewState = myReviewState
            self.myLastReviewAt = myLastReviewAt
            self.status = status
        }
    }

    /// Most PRs one GraphQL request carries. Each PR asks for up to 100 reviews and 100
    /// threads, so a bigger batch risks GitHub's node limit and a slow answer.
    static let snapshotBatchSize = 10
    /// Requests in flight at once. Few enough to stay polite to the API.
    static let snapshotConcurrency = 3

    /// One PR's snapshot. A batch of one — see `fetchPRSnapshots`.
    public func fetchPRSnapshot(for ref: PRLocator, login: String) async throws -> PRSnapshot {
        let batch = try await fetchSnapshotBatch(refs: [ref], login: login)
        guard let snapshot = batch[ref] else {
            throw GitHubError.decodingFailed("pull request \(ref.owner)/\(ref.repo)#\(ref.number) not returned")
        }
        return snapshot
    }

    /// Everything the refresh needs for many PRs: state, whether you approved, CI, readiness,
    /// and activity by the author or by reviewers. Batches of `snapshotBatchSize` PRs go out
    /// as one aliased GraphQL request each, a few at a time.
    ///
    /// A PR missing from the result was not returned — a failed batch, a deleted repository,
    /// a token that cannot see it. The caller keeps what it had, so a transient error never
    /// blanks the chips.
    public func fetchPRSnapshots(for refs: [PRLocator], login: String) async -> [PRLocator: PRSnapshot] {
        let unique = Array(Set(refs))
        let batches = stride(from: 0, to: unique.count, by: Self.snapshotBatchSize).map {
            Array(unique[$0..<min($0 + Self.snapshotBatchSize, unique.count)])
        }
        var merged: [PRLocator: PRSnapshot] = [:]
        var next = 0
        await withTaskGroup(of: [PRLocator: PRSnapshot].self) { group in
            func launch() {
                guard next < batches.count else { return }
                let batch = batches[next]
                next += 1
                group.addTask { (try? await self.fetchSnapshotBatch(refs: batch, login: login)) ?? [:] }
            }
            for _ in 0..<Self.snapshotConcurrency { launch() }
            while let result = await group.next() {
                merged.merge(result) { current, _ in current }
                launch()
            }
        }
        return merged
    }

    private func fetchSnapshotBatch(refs: [PRLocator], login: String) async throws -> [PRLocator: PRSnapshot] {
        var arguments = ["api", "graphql"]
        for (index, ref) in refs.enumerated() {
            arguments += ["-f", "o\(index)=\(ref.owner)", "-f", "n\(index)=\(ref.repo)", "-F", "p\(index)=\(ref.number)"]
        }
        arguments += ["-f", "query=\(Self.snapshotQuery(count: refs.count))"]
        let result = try await runner.run(executable: ghPath, arguments: arguments)

        // gh exits non-zero when any alias errors, yet still prints the aliases that worked.
        // One missing repository must not throw away the rest of the batch.
        let payload: GHSnapshotResponse
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            payload = try decoder.decode(GHSnapshotResponse.self, from: Data(result.standardOutput.utf8))
        } catch {
            if result.exitCode != 0 {
                throw GitHubError.commandFailed(exitCode: result.exitCode, message: result.standardError)
            }
            throw GitHubError.decodingFailed(String(describing: error))
        }
        var snapshots: [PRLocator: PRSnapshot] = [:]
        for (index, ref) in refs.enumerated() {
            if let pr = payload.data["r\(index)"]??.pullRequest {
                snapshots[ref] = Self.snapshot(from: pr, login: login)
            }
        }
        return snapshots
    }

    static func snapshot(from pr: GHSnapshotResponse.PullRequest, login: String) -> PRSnapshot {
        let headCommit = pr.commits.nodes.first?.commit

        let myReviews = pr.reviews.nodes.filter { $0.author?.login == login }
        let resolved = MyReviewState.resolve(
            from: myReviews.map { MyReviewSubmission(state: $0.state, submittedAt: $0.submittedAt) }
        )
        let approvedByMe = resolved.state == .approved

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

        let reviewerUpdate = pr.author?.login == login
            ? Self.reviewerUpdate(for: pr, myLogin: login, headCommittedAt: headCommit?.committedDate)
            : nil

        return PRSnapshot(
            prState: GitHubClient.mapState(state: pr.state, isDraft: pr.isDraft),
            approvedByMe: approvedByMe,
            myReviewState: resolved.state,
            myLastReviewAt: resolved.lastSubmittedAt,
            status: PRStatus(
                ci: Self.aggregateCI(rollup: headCommit?.statusCheckRollup),
                mergeState: PRStatus.mergeState(from: pr.mergeStateStatus),
                readiness: PRStatus.readiness(isDraft: pr.isDraft, reviewDecision: pr.reviewDecision),
                approvalCount: PRStatus.approvalCount(from: pr.reviews.nodes.compactMap {
                    guard let login = $0.author?.login else { return nil }
                    return ReviewSubmission(authorLogin: login, state: $0.state, submittedAt: $0.submittedAt)
                }),
                unresolvedThreads: threads.filter { !$0.isResolved }.count,
                authorUpdatedAt: authorUpdatedAt,
                reviewerUpdate: reviewerUpdate,
                updatedAt: pr.updatedAt,
                changeRequests: Self.changeRequests(for: pr)
            )
        )
    }

    /// Standing requests for changes, split by whether they were made on the current head.
    /// Bots are excluded, as they are from `reviewerUpdate`.
    static func changeRequests(for pr: GHSnapshotResponse.PullRequest) -> ChangeRequestTally {
        ChangeRequestTally.tally(
            verdicts: pr.reviews.nodes.compactMap { review in
                guard let login = review.author?.login, review.author?.typename != "Bot" else { return nil }
                return ReviewVerdict(login: login, state: review.state, commitOID: review.commit?.oid, at: review.submittedAt)
            },
            headOID: pr.headRefOid
        )
    }

    /// Collects what other people did on your PR, bots excluded. CI and app accounts post
    /// reviews and comments on every push, so counting them would badge every PR forever.
    static func reviewerUpdate(
        for pr: GHSnapshotResponse.PullRequest,
        myLogin: String,
        headCommittedAt: Date?
    ) -> ReviewerUpdate? {
        var events: [ReviewerEvent] = []
        var mine: [Date] = []

        func note(_ author: GHSnapshotResponse.Login?, at date: Date?, kind: ReviewerEvent.Kind) {
            guard let login = author?.login, let date, author?.typename != "Bot" else { return }
            if login == myLogin {
                mine.append(date)
            } else {
                events.append(ReviewerEvent(login: login, at: date, kind: kind))
            }
        }

        for review in pr.reviews.nodes {
            let kind: ReviewerEvent.Kind
            switch review.state {
            case "CHANGES_REQUESTED": kind = .changesRequested
            case "APPROVED": kind = .approved
            default: kind = .other
            }
            note(review.author, at: review.submittedAt, kind: kind)
        }
        for thread in pr.reviewThreads.nodes {
            for comment in thread.comments.nodes {
                note(comment.author, at: comment.createdAt, kind: .other)
            }
        }
        for comment in pr.comments?.nodes ?? [] {
            note(comment.author, at: comment.createdAt, kind: .other)
        }
        return ReviewerUpdate.latest(
            myLogin: myLogin,
            events: events,
            myActivity: mine,
            headCommittedAt: headCommittedAt
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

    /// One aliased `repository` lookup per PR, sharing a fragment. Owner, name and number
    /// travel as variables, never spliced into the text.
    static func snapshotQuery(count: Int) -> String {
        let variables = (0..<count).map { "$o\($0):String!,$n\($0):String!,$p\($0):Int!" }.joined(separator: ",")
        let lookups = (0..<count).map {
            "r\($0): repository(owner:$o\($0),name:$n\($0)){ pullRequest(number:$p\($0)){ ...F } }"
        }.joined(separator: "\n")
        return """
        query(\(variables)){
        \(lookups)
        }
        fragment F on PullRequest {
          state isDraft reviewDecision mergeStateStatus updatedAt headRefOid
          author{login}
          commits(last:1){nodes{commit{ committedDate
            statusCheckRollup{ state contexts(first:100){ totalCount nodes{
              __typename
              ... on CheckRun{ status conclusion }
              ... on StatusContext{ state }
            }}}
          }}}
          reviews(last:100){nodes{author{login __typename} state submittedAt commit{oid}}}
          reviewThreads(last:100){nodes{
            isResolved resolvedBy{login}
            comments(last:10){nodes{author{login __typename} createdAt}}
          }}
          comments(last:30){nodes{author{login __typename} createdAt}}
          timelineItems(last:50, itemTypes:[REVIEW_REQUESTED_EVENT]){nodes{
            ... on ReviewRequestedEvent{ createdAt requestedReviewer{ ... on User{login} } }
          }}
        }
        """
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
    public let updatedAt: String?

    public var id: String { "\(owner)/\(repo)/issues/\(number)" }
    public var locator: IssueLocator { IssueLocator(owner: owner, repo: repo, number: number) }

    public init(owner: String, repo: String, number: Int, title: String, url: String, authorLogin: String, state: String, updatedAt: String? = nil) {
        self.owner = owner
        self.repo = repo
        self.number = number
        self.title = title
        self.url = url
        self.authorLogin = authorLogin
        self.state = state
        self.updatedAt = updatedAt
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
    public let updatedAt: String?

    public var id: String { "\(owner)/\(repo)#\(number)" }
    public var ref: PRLocator { PRLocator(owner: owner, repo: repo, number: number) }

    public init(owner: String, repo: String, number: Int, title: String, url: String, authorLogin: String, state: String, isDraft: Bool, updatedAt: String? = nil) {
        self.owner = owner
        self.repo = repo
        self.number = number
        self.title = title
        self.url = url
        self.authorLogin = authorLogin
        self.state = state
        self.isDraft = isDraft
        self.updatedAt = updatedAt
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
    let updatedAt: String?
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
    let updatedAt: String?
    let author: Author
    let repository: Repository
}

extension GitHubClient {
    public func searchPRs(query: String) async throws -> [DiscoveryHit] {
        let fields = "number,title,url,state,isDraft,author,repository,updatedAt"
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
                isDraft: row.isDraft,
                updatedAt: row.updatedAt
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
        let fields = "number,title,url,state,author,repository,updatedAt"
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
                url: row.url, authorLogin: row.author.login, state: row.state,
                updatedAt: row.updatedAt
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

/// One entry from `gh api repos/{o}/{r}/rules/branches/{branch}`. Every rule type shares
/// the envelope; only the `pull_request` rule carries parameters this app reads, and other
/// rule types carry a `parameters` object of an entirely different shape — hence the
/// optional and the single field.
struct GHBranchRule: Decodable {
    struct Parameters: Decodable {
        let requiredApprovingReviewCount: Int?

        enum CodingKeys: String, CodingKey {
            case requiredApprovingReviewCount = "required_approving_review_count"
        }
    }
    let type: String
    let parameters: Parameters?
}

struct GHSnapshotResponse: Decodable {
    /// `login` is optional because an inline fragment that does not match yields an empty
    /// object rather than null — a team review request decodes as `{}`.
    struct Login: Decodable {
        let login: String?
        /// Only present where the query asks for it. `Bot` marks CI and app accounts.
        let typename: String?

        private enum CodingKeys: String, CodingKey {
            case login
            case typename = "__typename"
        }
    }

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

    struct ReviewCommit: Decodable { let oid: String? }
    struct Review: Decodable {
        let author: Login?   // null for reviews by deleted accounts
        let state: String
        let submittedAt: Date?
        /// The commit the review was made against. Null once GitHub has dropped it.
        let commit: ReviewCommit?
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
        let updatedAt: Date?
        let headRefOid: String?
        let author: Login?
        let commits: Commits
        let reviews: Reviews
        let reviewThreads: ReviewThreads
        let comments: Comments?
        let timelineItems: TimelineItems
    }
    /// `null` for an alias GitHub could not resolve.
    struct Repository: Decodable { let pullRequest: PullRequest? }
    /// Keyed by the alias, `r0`, `r1`, … in the order the PRs were asked for.
    let data: [String: Repository?]
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

/// The readable part of an issue or PR: its description and the discussion under it.
public struct GitHubThread: Sendable, Equatable {
    public struct Entry: Sendable, Equatable {
        public let author: String
        public let at: String?
        public let body: String
        /// Review verdict such as `APPROVED`, for PR reviews. Nil for plain comments.
        public let verdict: String?

        public init(author: String, at: String?, body: String, verdict: String? = nil) {
            self.author = author
            self.at = at
            self.body = body
            self.verdict = verdict
        }
    }

    public let title: String
    public let state: String
    public let author: String
    public let createdAt: String?
    public let body: String
    public let labels: [String]
    public let entries: [Entry]

    public init(title: String, state: String, author: String, createdAt: String?, body: String, labels: [String], entries: [Entry]) {
        self.title = title
        self.state = state
        self.author = author
        self.createdAt = createdAt
        self.body = body
        self.labels = labels
        self.entries = entries
    }
}

private struct GHThread: Decodable {
    struct Author: Decodable { let login: String }
    struct Label: Decodable { let name: String }
    struct Comment: Decodable {
        let author: Author?
        let body: String
        let createdAt: String?
    }
    struct Review: Decodable {
        let author: Author?
        let body: String
        let state: String
        let submittedAt: String?
    }
    let title: String
    let state: String
    let author: Author?
    let createdAt: String?
    let body: String
    let labels: [Label]
    let comments: [Comment]
    let reviews: [Review]?
}

extension GitHubClient {
    /// Reads the description and discussion of an issue or PR through `gh`. The phone cannot
    /// embed github.com, so the Mac fetches the text and the phone draws it.
    public func fetchThread(owner: String, repo: String, number: Int, isPR: Bool) async throws -> GitHubThread {
        let fields = isPR
            ? "title,state,author,createdAt,body,labels,comments,reviews"
            : "title,state,author,createdAt,body,labels,comments"
        let result = try await runner.run(
            executable: ghPath,
            arguments: [isPR ? "pr" : "issue", "view", String(number), "--repo", "\(owner)/\(repo)", "--json", fields]
        )
        guard result.exitCode == 0 else {
            throw GitHubError.commandFailed(exitCode: result.exitCode, message: result.standardError)
        }
        let raw: GHThread
        do {
            raw = try JSONDecoder().decode(GHThread.self, from: Data(result.standardOutput.utf8))
        } catch {
            throw GitHubError.decodingFailed(String(describing: error))
        }

        let comments = raw.comments.map {
            GitHubThread.Entry(author: $0.author?.login ?? "ghost", at: $0.createdAt, body: $0.body)
        }
        let reviews = (raw.reviews ?? [])
            .filter { !$0.body.isEmpty || $0.state != "COMMENTED" }
            .map {
                GitHubThread.Entry(author: $0.author?.login ?? "ghost", at: $0.submittedAt, body: $0.body, verdict: $0.state)
            }
        let entries = (comments + reviews).sorted { ($0.at ?? "") < ($1.at ?? "") }

        return GitHubThread(
            title: raw.title,
            state: raw.state,
            author: raw.author?.login ?? "ghost",
            createdAt: raw.createdAt,
            body: raw.body,
            labels: raw.labels.map(\.name),
            entries: entries
        )
    }
}
