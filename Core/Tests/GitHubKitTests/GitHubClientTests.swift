import Testing
import Foundation
import PRPilotModels
import CommandSupport
@testable import GitHubKit

private actor RecordingRunner: CommandRunner {
    let result: CommandResult?
    private var results: [CommandResult]
    private(set) var lastExecutable: String?
    private(set) var lastArguments: [String]?
    private(set) var invocationCount = 0

    init(result: CommandResult) {
        self.result = result
        self.results = []
    }

    init(results: [CommandResult]) {
        self.result = nil
        self.results = results
    }

    func run(executable: String, arguments: [String]) async throws -> CommandResult {
        lastExecutable = executable
        lastArguments = arguments
        invocationCount += 1
        if !results.isEmpty {
            return results.removeFirst()
        }
        return result!
    }
}

private actor QueuedRunner: CommandRunner {
    private var results: [CommandResult]
    private(set) var allArguments: [[String]] = []

    init(_ results: [CommandResult]) {
        self.results = results
    }

    func run(executable: String, arguments: [String]) async throws -> CommandResult {
        allArguments.append(arguments)
        return results.isEmpty ? CommandResult(exitCode: 0, standardOutput: "[]", standardError: "") : results.removeFirst()
    }
}

private let unknownFieldStderr = """
Unknown JSON field: "closingIssuesReferences"
Available fields:
  number
  title
  url
  state
  isDraft
  author
  headRefName
  baseRefName
"""

private let samplePRJSON = """
{
  "number": 944,
  "title": "fix(asset/centrifuge): speak bidirectional Centrifuge protocol",
  "url": "https://github.com/bsv-blockchain/teranode/pull/944",
  "state": "OPEN",
  "isDraft": false,
  "author": { "login": "icellan" },
  "headRefName": "fix/centrifuge-bidirectional",
  "baseRefName": "main",
  "closingIssuesReferences": []
}
"""

private let samplePRJSONWithClosingIssue = """
{
  "number": 944,
  "title": "fix(asset/centrifuge): speak bidirectional Centrifuge protocol",
  "url": "https://github.com/bsv-blockchain/teranode/pull/944",
  "state": "OPEN",
  "isDraft": false,
  "author": { "login": "icellan" },
  "headRefName": "fix/centrifuge-bidirectional",
  "baseRefName": "main",
  "closingIssuesReferences": [{ "number": 123 }, { "number": 456 }]
}
"""

@Test func fetchReviewMapsJSONToReview() async throws {
    let runner = RecordingRunner(result: CommandResult(exitCode: 0, standardOutput: samplePRJSON, standardError: ""))
    let client = GitHubClient(runner: runner, ghPath: "/opt/homebrew/bin/gh")
    let ref = PRLocator(owner: "bsv-blockchain", repo: "teranode", number: 944)
    let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

    let review = try await client.fetchReview(for: ref, origin: .added, now: fixedDate)

    #expect(review.repoKey == "github.com/bsv-blockchain/teranode")
    #expect(review.prRef?.owner == "bsv-blockchain")
    #expect(review.prRef?.repo == "teranode")
    #expect(review.prRef?.number == 944)
    #expect(review.prRef?.authorLogin == "icellan")
    #expect(review.headBranch == "fix/centrifuge-bidirectional")
    #expect(review.baseBranch == "main")
    #expect(review.prRef?.url.absoluteString == "https://github.com/bsv-blockchain/teranode/pull/944")
    #expect(review.origin == .added)
    #expect(review.title == "fix(asset/centrifuge): speak bidirectional Centrifuge protocol")
    #expect(review.prState == .open)
    #expect(review.addedAt == fixedDate)
    #expect(review.closingIssueNumber == nil)

    let args = await runner.lastArguments
    #expect(args == ["pr", "view", "944", "--repo", "bsv-blockchain/teranode", "--json", "number,title,url,state,isDraft,author,headRefName,baseRefName,closingIssuesReferences"])
    let executable = await runner.lastExecutable
    #expect(executable == "/opt/homebrew/bin/gh")
}

@Test func fetchReviewThrowsOnNonZeroExit() async {
    let runner = RecordingRunner(result: CommandResult(exitCode: 1, standardOutput: "", standardError: "no pull requests found"))
    let client = GitHubClient(runner: runner, ghPath: "gh")
    let ref = PRLocator(owner: "bsv-blockchain", repo: "teranode", number: 999)

    await #expect(throws: GitHubError.self) {
        try await client.fetchReview(for: ref)
    }
}

@Test func fetchDefaultBaseUsesOwnDefaultForNonFork() async throws {
    let json = """
    {"isFork": false, "parent": null, "defaultBranchRef": {"name": "develop"}}
    """
    let runner = RecordingRunner(result: CommandResult(exitCode: 0, standardOutput: json, standardError: ""))
    let client = GitHubClient(runner: runner, ghPath: "gh")

    let base = try await client.fetchDefaultBase(owner: "acme", repo: "app")
    #expect(base == "develop")
    let args = await runner.lastArguments
    #expect(args == ["repo", "view", "acme/app", "--json", "isFork,parent,defaultBranchRef"])
}

@Test func fetchDefaultBaseUsesParentDefaultForFork() async throws {
    let forkJSON = """
    {"isFork": true, "parent": {"name": "teranode", "owner": {"login": "bsv-blockchain"}}, "defaultBranchRef": {"name": "patch-1"}}
    """
    let parentJSON = """
    {"isFork": false, "parent": null, "defaultBranchRef": {"name": "main"}}
    """
    let runner = QueuedRunner([
        CommandResult(exitCode: 0, standardOutput: forkJSON, standardError: ""),
        CommandResult(exitCode: 0, standardOutput: parentJSON, standardError: ""),
    ])
    let client = GitHubClient(runner: runner, ghPath: "gh")

    let base = try await client.fetchDefaultBase(owner: "me", repo: "teranode")
    #expect(base == "main")
    let calls = await runner.allArguments
    #expect(calls.count == 2)
    #expect(calls[1] == ["repo", "view", "bsv-blockchain/teranode", "--json", "isFork,parent,defaultBranchRef"])
}

@Test func fetchDefaultBaseFallsBackToOwnWhenParentLookupFails() async throws {
    let forkJSON = """
    {"isFork": true, "parent": {"name": "teranode", "owner": {"login": "bsv-blockchain"}}, "defaultBranchRef": {"name": "patch-1"}}
    """
    let runner = QueuedRunner([
        CommandResult(exitCode: 0, standardOutput: forkJSON, standardError: ""),
        CommandResult(exitCode: 1, standardOutput: "", standardError: "network error"),
    ])
    let client = GitHubClient(runner: runner, ghPath: "gh")

    let base = try await client.fetchDefaultBase(owner: "me", repo: "teranode")
    #expect(base == "patch-1")
}

@Test func fetchDefaultBaseThrowsWhenPrimaryViewFails() async {
    let runner = RecordingRunner(result: CommandResult(exitCode: 1, standardOutput: "", standardError: "not found"))
    let client = GitHubClient(runner: runner, ghPath: "gh")

    await #expect(throws: GitHubError.self) {
        _ = try await client.fetchDefaultBase(owner: "acme", repo: "missing")
    }
}

@Test func mapStateCoversAllCases() {
    #expect(GitHubClient.mapState(state: "OPEN", isDraft: false) == .open)
    #expect(GitHubClient.mapState(state: "OPEN", isDraft: true) == .draft)
    #expect(GitHubClient.mapState(state: "MERGED", isDraft: false) == .merged)
    #expect(GitHubClient.mapState(state: "MERGED", isDraft: true) == .merged)
    #expect(GitHubClient.mapState(state: "CLOSED", isDraft: false) == .closed)
    #expect(GitHubClient.mapState(state: "CLOSED", isDraft: true) == .closed)
}

@Test func fetchReviewThrowsOnBadJSON() async {
    let runner = RecordingRunner(result: CommandResult(exitCode: 0, standardOutput: "{}", standardError: ""))
    let client = GitHubClient(runner: runner, ghPath: "gh")
    let ref = PRLocator(owner: "bsv-blockchain", repo: "teranode", number: 944)

    await #expect(throws: GitHubError.self) {
        try await client.fetchReview(for: ref)
    }
}

@Test func fetchReviewPopulatesClosingIssueNumber() async throws {
    let runner = RecordingRunner(result: CommandResult(exitCode: 0, standardOutput: samplePRJSONWithClosingIssue, standardError: ""))
    let client = GitHubClient(runner: runner, ghPath: "gh")
    let ref = PRLocator(owner: "bsv-blockchain", repo: "teranode", number: 944)

    let review = try await client.fetchReview(for: ref)

    #expect(review.closingIssueNumber == 123)
}

@Test func fetchReviewRetriesWithoutClosingIssuesOnOlderGh() async throws {
    let runner = QueuedRunner([
        CommandResult(exitCode: 1, standardOutput: "", standardError: unknownFieldStderr),
        CommandResult(exitCode: 0, standardOutput: samplePRJSON, standardError: ""),
    ])
    let client = GitHubClient(runner: runner, ghPath: "gh")
    let ref = PRLocator(owner: "bsv-blockchain", repo: "teranode", number: 944)

    let review = try await client.fetchReview(for: ref)

    #expect(review.prRef?.number == 944)
    #expect(review.closingIssueNumber == nil)

    let calls = await runner.allArguments
    #expect(calls.count == 2)
    #expect(calls[0].last == "number,title,url,state,isDraft,author,headRefName,baseRefName,closingIssuesReferences")
    #expect(calls[1].last == "number,title,url,state,isDraft,author,headRefName,baseRefName")
}

@Test func fetchReviewDoesNotRetryOnUnrelatedError() async {
    let runner = QueuedRunner([
        CommandResult(exitCode: 1, standardOutput: "", standardError: "no pull requests found"),
    ])
    let client = GitHubClient(runner: runner, ghPath: "gh")
    let ref = PRLocator(owner: "bsv-blockchain", repo: "teranode", number: 944)

    await #expect(throws: GitHubError.self) {
        try await client.fetchReview(for: ref)
    }

    let calls = await runner.allArguments
    #expect(calls.count == 1)
}

private let sampleSearchJSON = """
[
  {
    "number": 944,
    "title": "fix(asset/centrifuge): speak bidirectional Centrifuge protocol",
    "url": "https://github.com/bsv-blockchain/teranode/pull/944",
    "state": "open",
    "isDraft": false,
    "author": { "login": "icellan" },
    "repository": { "nameWithOwner": "bsv-blockchain/teranode" }
  },
  {
    "number": 17,
    "title": "WIP",
    "url": "https://github.com/foo/bar/pull/17",
    "state": "open",
    "isDraft": true,
    "author": { "login": "alice" },
    "repository": { "nameWithOwner": "foo/bar" }
  }
]
"""

private let sampleSearchJSONWithMalformedRepo = """
[
  {
    "number": 944,
    "title": "ok",
    "url": "https://github.com/bsv-blockchain/teranode/pull/944",
    "state": "open",
    "isDraft": false,
    "author": { "login": "icellan" },
    "repository": { "nameWithOwner": "bsv-blockchain/teranode" }
  },
  {
    "number": 99,
    "title": "broken",
    "url": "https://example.com/x",
    "state": "open",
    "isDraft": false,
    "author": { "login": "x" },
    "repository": { "nameWithOwner": "no-slash-here" }
  }
]
"""

@Test func searchPRsParsesResults() async throws {
    let runner = RecordingRunner(result: CommandResult(exitCode: 0, standardOutput: sampleSearchJSON, standardError: ""))
    let client = GitHubClient(runner: runner, ghPath: "/opt/homebrew/bin/gh")

    let hits = try await client.searchPRs(query: "review-requested:@me")

    #expect(hits.count == 2)
    #expect(hits[0].owner == "bsv-blockchain")
    #expect(hits[0].repo == "teranode")
    #expect(hits[0].number == 944)
    #expect(hits[0].title == "fix(asset/centrifuge): speak bidirectional Centrifuge protocol")
    #expect(hits[0].authorLogin == "icellan")
    #expect(hits[0].state == "open")
    #expect(hits[0].isDraft == false)
    #expect(hits[0].id == "bsv-blockchain/teranode#944")

    #expect(hits[1].owner == "foo")
    #expect(hits[1].repo == "bar")
    #expect(hits[1].isDraft == true)
    #expect(hits[1].authorLogin == "alice")

    let args = await runner.lastArguments
    #expect(args == ["search", "prs", "review-requested:@me", "--json", "number,title,url,state,isDraft,author,repository", "--limit", "100"])
}

@Test func searchPRsHandlesEmptyResults() async throws {
    let runner = RecordingRunner(result: CommandResult(exitCode: 0, standardOutput: "[]", standardError: ""))
    let client = GitHubClient(runner: runner, ghPath: "gh")

    let hits = try await client.searchPRs(query: "assignee:@me")

    #expect(hits.isEmpty)
}

@Test func searchPRsThrowsOnNonZeroExit() async {
    let runner = RecordingRunner(result: CommandResult(exitCode: 1, standardOutput: "", standardError: "auth required"))
    let client = GitHubClient(runner: runner, ghPath: "gh")

    await #expect(throws: GitHubError.self) {
        try await client.searchPRs(query: "review-requested:@me")
    }
}

@Test func searchPRsSkipsMalformedRepository() async throws {
    let runner = RecordingRunner(result: CommandResult(exitCode: 0, standardOutput: sampleSearchJSONWithMalformedRepo, standardError: ""))
    let client = GitHubClient(runner: runner, ghPath: "gh")

    let hits = try await client.searchPRs(query: "x")

    #expect(hits.count == 1)
    #expect(hits.first?.owner == "bsv-blockchain")
    #expect(hits.first?.repo == "teranode")
}

@Test func searchPRsSplitsMultiQualifierQueryIntoSeparateArgs() async throws {
    let runner = RecordingRunner(result: CommandResult(exitCode: 0, standardOutput: "[]", standardError: ""))
    let client = GitHubClient(runner: runner, ghPath: "gh")

    _ = try await client.searchPRs(query: "review-requested:@me is:open")

    let args = await runner.lastArguments
    #expect(args == ["search", "prs", "review-requested:@me", "is:open", "--json", "number,title,url,state,isDraft,author,repository", "--limit", "100"])
}

@Test func mapDiscoveryStateNormalizesCasing() {
    #expect(GitHubClient.mapDiscoveryState(state: "open", isDraft: false) == .open)
    #expect(GitHubClient.mapDiscoveryState(state: "open", isDraft: true) == .draft)
    #expect(GitHubClient.mapDiscoveryState(state: "merged", isDraft: false) == .merged)
    #expect(GitHubClient.mapDiscoveryState(state: "closed", isDraft: false) == .closed)
    #expect(GitHubClient.mapDiscoveryState(state: "MERGED", isDraft: false) == .merged)
}

@Test func fetchCurrentLoginTrimsOutput() async throws {
    let runner = RecordingRunner(result: CommandResult(exitCode: 0, standardOutput: "ordishs\n", standardError: ""))
    let client = GitHubClient(runner: runner, ghPath: "/opt/homebrew/bin/gh")
    let login = try await client.fetchCurrentLogin()
    #expect(login == "ordishs")
    let args = await runner.lastArguments
    #expect(args == ["api", "user", "--jq", ".login"])
}

private func snapshotJSON(
    state: String = "OPEN",
    isDraft: Bool = false,
    mergeStateStatus: String = "CLEAN",
    reviewDecision: String? = nil,
    author: String = "icellan",
    committedDate: String? = nil,
    rollupJSON: String = "null",
    reviewsJSON: String = "[]",
    threadsJSON: String = "[]",
    timelineJSON: String = "[]"
) -> String {
    let decision = reviewDecision.map { "\"\($0)\"" } ?? "null"
    let committed = committedDate.map { "\"\($0)\"" } ?? "null"
    return """
    {"data":{"repository":{"pullRequest":{
      "state":"\(state)","isDraft":\(isDraft),"reviewDecision":\(decision),
      "mergeStateStatus":"\(mergeStateStatus)","author":{"login":"\(author)"},
      "commits":{"nodes":[{"commit":{"committedDate":\(committed),"statusCheckRollup":\(rollupJSON)}}]},
      "reviews":{"nodes":\(reviewsJSON)},
      "reviewThreads":{"nodes":\(threadsJSON)},
      "timelineItems":{"nodes":\(timelineJSON)}
    }}}}
    """
}

private func snapshotClient(_ json: String) -> (GitHubClient, RecordingRunner) {
    let runner = RecordingRunner(result: CommandResult(exitCode: 0, standardOutput: json, standardError: ""))
    return (GitHubClient(runner: runner, ghPath: "/usr/bin/gh"), runner)
}

private let snapshotRef = PRLocator(owner: "bsv-blockchain", repo: "teranode", number: 944)

@Test func snapshotApprovedWhenMyLatestDecisiveReviewIsApproved() async throws {
    let reviews = """
    [{"author":{"login":"someoneelse"},"state":"CHANGES_REQUESTED","submittedAt":"2026-08-01T09:00:00Z"},
     {"author":{"login":"ordishs"},"state":"COMMENTED","submittedAt":"2026-08-01T10:00:00Z"},
     {"author":{"login":"ordishs"},"state":"APPROVED","submittedAt":"2026-08-01T11:00:00Z"},
     {"author":{"login":"ordishs"},"state":"COMMENTED","submittedAt":"2026-08-01T12:00:00Z"}]
    """
    let (client, _) = snapshotClient(snapshotJSON(reviewsJSON: reviews))
    let snapshot = try await client.fetchPRSnapshot(for: snapshotRef, login: "ordishs")
    #expect(snapshot.approvedByMe == true)
    #expect(snapshot.prState == .open)
}

@Test func snapshotNotApprovedWhenMyApprovalWasDismissed() async throws {
    let reviews = """
    [{"author":{"login":"ordishs"},"state":"APPROVED","submittedAt":"2026-08-01T10:00:00Z"},
     {"author":{"login":"ordishs"},"state":"DISMISSED","submittedAt":"2026-08-01T11:00:00Z"}]
    """
    let (client, _) = snapshotClient(snapshotJSON(reviewsJSON: reviews))
    let snapshot = try await client.fetchPRSnapshot(for: snapshotRef, login: "ordishs")
    #expect(snapshot.approvedByMe == false)
}

@Test func snapshotNotApprovedWhenOnlySomeoneElseApproved() async throws {
    let reviews = """
    [{"author":{"login":"someoneelse"},"state":"APPROVED","submittedAt":"2026-08-01T10:00:00Z"}]
    """
    let (client, _) = snapshotClient(snapshotJSON(state: "MERGED", reviewsJSON: reviews))
    let snapshot = try await client.fetchPRSnapshot(for: snapshotRef, login: "ordishs")
    #expect(snapshot.approvedByMe == false)
    #expect(snapshot.prState == .merged)
}

@Test func snapshotThrowsOnNonZeroExit() async {
    let runner = RecordingRunner(result: CommandResult(exitCode: 1, standardOutput: "", standardError: "no pull requests found"))
    let client = GitHubClient(runner: runner, ghPath: "gh")
    await #expect(throws: GitHubError.self) {
        try await client.fetchPRSnapshot(for: snapshotRef, login: "ordishs")
    }
}

@Test func snapshotParsesChecksBehindAndDecision() async throws {
    let rollup = """
    {"state":"PENDING","contexts":{"totalCount":2,"nodes":[
      {"__typename":"CheckRun","status":"COMPLETED","conclusion":"SUCCESS"},
      {"__typename":"StatusContext","state":"PENDING"}]}}
    """
    let (client, _) = snapshotClient(snapshotJSON(
        mergeStateStatus: "BEHIND",
        reviewDecision: "CHANGES_REQUESTED",
        rollupJSON: rollup
    ))
    let snapshot = try await client.fetchPRSnapshot(for: snapshotRef, login: "ordishs")
    #expect(snapshot.status.ci == .pending)
    #expect(snapshot.status.isBehind == true)
    #expect(snapshot.status.readiness == .changesRequested)
}

@Test func snapshotHandlesNullRollupAndCleanMerge() async throws {
    let (client, _) = snapshotClient(snapshotJSON(isDraft: true))
    let snapshot = try await client.fetchPRSnapshot(for: snapshotRef, login: "ordishs")
    #expect(snapshot.status.ci == .none)
    #expect(snapshot.status.isBehind == false)
    #expect(snapshot.status.readiness == .draft)
}

@Test func snapshotFallsBackToRollupStateWhenContextsArePaginated() async throws {
    // 150 checks, only 100 fetched: the unfetched remainder could hide the failure that
    // the rollup itself is reporting, so the rollup state wins.
    let rollup = """
    {"state":"FAILURE","contexts":{"totalCount":150,"nodes":[
      {"__typename":"CheckRun","status":"COMPLETED","conclusion":"SUCCESS"}]}}
    """
    let (client, _) = snapshotClient(snapshotJSON(rollupJSON: rollup))
    let snapshot = try await client.fetchPRSnapshot(for: snapshotRef, login: "ordishs")
    #expect(snapshot.status.ci == .failing)
}

@Test func snapshotFlagsAuthorUpdateFromPushAndReRequest() async throws {
    // The real shape of teranode#1466: you requested changes at 09:21, freemans13 pushed
    // at 11:06 and re-requested your review at 12:00.
    let reviews = """
    [{"author":{"login":"ordishs"},"state":"CHANGES_REQUESTED","submittedAt":"2026-08-06T09:21:56Z"}]
    """
    let timeline = """
    [{"createdAt":"2026-08-06T12:00:29Z","requestedReviewer":{"login":"ordishs"}}]
    """
    let (client, _) = snapshotClient(snapshotJSON(
        author: "freemans13",
        committedDate: "2026-08-06T11:06:48Z",
        reviewsJSON: reviews,
        timelineJSON: timeline
    ))
    let snapshot = try await client.fetchPRSnapshot(for: snapshotRef, login: "ordishs")
    #expect(snapshot.status.authorUpdatedAt == ISO8601DateFormatter().date(from: "2026-08-06T12:00:29Z"))
}

@Test func snapshotFlagsAuthorUpdateFromThreadReply() async throws {
    let reviews = """
    [{"author":{"login":"ordishs"},"state":"CHANGES_REQUESTED","submittedAt":"2026-08-06T09:00:00Z"}]
    """
    let threads = """
    [{"isResolved":true,"resolvedBy":{"login":"icellan"},"comments":{"nodes":[
      {"author":{"login":"ordishs"},"createdAt":"2026-08-06T09:00:00Z"},
      {"author":{"login":"icellan"},"createdAt":"2026-08-06T10:30:00Z"}]}}]
    """
    let (client, _) = snapshotClient(snapshotJSON(reviewsJSON: reviews, threadsJSON: threads))
    let snapshot = try await client.fetchPRSnapshot(for: snapshotRef, login: "ordishs")
    #expect(snapshot.status.authorUpdatedAt == ISO8601DateFormatter().date(from: "2026-08-06T10:30:00Z"))
}

@Test func snapshotHasNoAuthorUpdateWhenYourReviewIsNewest() async throws {
    let reviews = """
    [{"author":{"login":"ordishs"},"state":"APPROVED","submittedAt":"2026-08-06T13:00:00Z"}]
    """
    let timeline = """
    [{"createdAt":"2026-08-06T12:00:29Z","requestedReviewer":{"login":"ordishs"}}]
    """
    let (client, _) = snapshotClient(snapshotJSON(
        committedDate: "2026-08-06T11:06:48Z",
        reviewsJSON: reviews,
        timelineJSON: timeline
    ))
    let snapshot = try await client.fetchPRSnapshot(for: snapshotRef, login: "ordishs")
    #expect(snapshot.status.authorUpdatedAt == nil)
}

@Test func snapshotToleratesTeamReviewRequestsWithNoUserLogin() async throws {
    // requestedReviewer is a Team: the `... on User` fragment does not match, and GitHub
    // returns an empty object rather than null. Decoding must survive it.
    let reviews = """
    [{"author":{"login":"ordishs"},"state":"COMMENTED","submittedAt":"2026-08-06T09:00:00Z"}]
    """
    let (client, _) = snapshotClient(snapshotJSON(
        reviewsJSON: reviews,
        timelineJSON: """
        [{"createdAt":"2026-08-06T12:00:29Z","requestedReviewer":{}}]
        """
    ))
    let snapshot = try await client.fetchPRSnapshot(for: snapshotRef, login: "ordishs")
    #expect(snapshot.status.authorUpdatedAt == nil)
}

@Test func snapshotIssuesOneGraphQLCall() async throws {
    let (client, runner) = snapshotClient(snapshotJSON())
    _ = try await client.fetchPRSnapshot(for: snapshotRef, login: "ordishs")
    let args = await runner.lastArguments
    #expect(await runner.invocationCount == 1)
    #expect(args?.prefix(2) == ["api", "graphql"])
    #expect(args?.contains("owner=bsv-blockchain") == true)
    #expect(args?.contains("number=944") == true)
}

private let sampleIssueSearchJSON = """
[
  {
    "number": 42,
    "title": "Login crashes on empty password",
    "url": "https://github.com/bsv-blockchain/teranode/issues/42",
    "state": "open",
    "author": { "login": "alice" },
    "repository": { "nameWithOwner": "bsv-blockchain/teranode" }
  }
]
"""

private let sampleIssueViewJSON = """
{
  "number": 42,
  "title": "Login crashes on empty password",
  "url": "https://github.com/bsv-blockchain/teranode/issues/42",
  "state": "OPEN",
  "author": { "login": "alice" }
}
"""

private let repoViewMainJSON = """
{ "isFork": false, "parent": null, "defaultBranchRef": { "name": "main" } }
"""

@Test func searchIssuesParsesResultsAndAppendsIsIssue() async throws {
    let runner = RecordingRunner(result: CommandResult(exitCode: 0, standardOutput: sampleIssueSearchJSON, standardError: ""))
    let client = GitHubClient(runner: runner, ghPath: "gh")

    let hits = try await client.searchIssues(query: "assignee:@me is:open")

    #expect(hits.count == 1)
    #expect(hits[0].owner == "bsv-blockchain")
    #expect(hits[0].repo == "teranode")
    #expect(hits[0].number == 42)
    #expect(hits[0].authorLogin == "alice")
    #expect(hits[0].state == "open")
    #expect(hits[0].id == "bsv-blockchain/teranode/issues/42")
    #expect(hits[0].locator == IssueLocator(owner: "bsv-blockchain", repo: "teranode", number: 42))

    let args = await runner.lastArguments
    #expect(args == ["search", "issues", "assignee:@me", "is:open", "is:issue", "--json", "number,title,url,state,author,repository", "--limit", "100"])
}

@Test func searchIssuesDoesNotDuplicateIsIssue() async throws {
    let runner = RecordingRunner(result: CommandResult(exitCode: 0, standardOutput: "[]", standardError: ""))
    let client = GitHubClient(runner: runner, ghPath: "gh")
    _ = try await client.searchIssues(query: "assignee:@me is:issue")
    let args = await runner.lastArguments
    #expect(args == ["search", "issues", "assignee:@me", "is:issue", "--json", "number,title,url,state,author,repository", "--limit", "100"])
}

@Test func searchIssuesThrowsOnNonZeroExit() async {
    let runner = RecordingRunner(result: CommandResult(exitCode: 1, standardOutput: "", standardError: "auth required"))
    let client = GitHubClient(runner: runner, ghPath: "gh")
    await #expect(throws: GitHubError.self) {
        try await client.searchIssues(query: "assignee:@me")
    }
}

@Test func fetchIssueBuildsWorkItemWithBranchAndBase() async throws {
    // First call: gh issue view → issue JSON. Second call: gh repo view → default base.
    let runner = RecordingRunner(results: [
        CommandResult(exitCode: 0, standardOutput: sampleIssueViewJSON, standardError: ""),
        CommandResult(exitCode: 0, standardOutput: repoViewMainJSON, standardError: ""),
    ])
    let client = GitHubClient(runner: runner, ghPath: "gh")

    let item = try await client.fetchIssue(
        for: IssueLocator(owner: "bsv-blockchain", repo: "teranode", number: 42),
        origin: .discovered
    )

    #expect(item.prRef == nil)
    #expect(item.issueRef?.number == 42)
    #expect(item.issueRef?.authorLogin == "alice")
    #expect(item.repoKey == "github.com/bsv-blockchain/teranode")
    #expect(item.baseBranch == "main")
    #expect(item.headBranch == "issue-42-login-crashes-on-empty-password")
    #expect(item.prState == .open)
    #expect(item.origin == .discovered)
    #expect(item.category(myLogin: nil) == .issue)
}
