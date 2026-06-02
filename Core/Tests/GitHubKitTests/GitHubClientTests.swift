import Testing
import Foundation
import PRPilotModels
import CommandSupport
@testable import GitHubKit

private actor RecordingRunner: CommandRunner {
    let result: CommandResult
    private(set) var lastExecutable: String?
    private(set) var lastArguments: [String]?

    init(result: CommandResult) {
        self.result = result
    }

    func run(executable: String, arguments: [String]) async throws -> CommandResult {
        lastExecutable = executable
        lastArguments = arguments
        return result
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

@Test func fetchReviewStateApprovedWhenMyLatestDecisiveReviewIsApproved() async throws {
    let json = """
    {"state":"OPEN","isDraft":false,"reviews":[
      {"author":{"login":"someoneelse"},"state":"CHANGES_REQUESTED"},
      {"author":{"login":"ordishs"},"state":"COMMENTED"},
      {"author":{"login":"ordishs"},"state":"APPROVED"},
      {"author":{"login":"ordishs"},"state":"COMMENTED"}
    ]}
    """
    let runner = RecordingRunner(result: CommandResult(exitCode: 0, standardOutput: json, standardError: ""))
    let client = GitHubClient(runner: runner, ghPath: "gh")
    let ref = PRLocator(owner: "bsv-blockchain", repo: "teranode", number: 944)
    let state = try await client.fetchReviewState(for: ref, login: "ordishs")
    #expect(state.approvedByMe == true)
    #expect(state.prState == .open)
}

@Test func fetchReviewStateNotApprovedWhenMyApprovalWasDismissed() async throws {
    let json = """
    {"state":"OPEN","isDraft":false,"reviews":[
      {"author":{"login":"ordishs"},"state":"APPROVED"},
      {"author":{"login":"ordishs"},"state":"DISMISSED"}
    ]}
    """
    let runner = RecordingRunner(result: CommandResult(exitCode: 0, standardOutput: json, standardError: ""))
    let client = GitHubClient(runner: runner, ghPath: "gh")
    let ref = PRLocator(owner: "bsv-blockchain", repo: "teranode", number: 944)
    let state = try await client.fetchReviewState(for: ref, login: "ordishs")
    #expect(state.approvedByMe == false)
}

@Test func fetchReviewStateNotApprovedWhenOnlySomeoneElseApproved() async throws {
    let json = """
    {"state":"MERGED","isDraft":false,"reviews":[
      {"author":{"login":"someoneelse"},"state":"APPROVED"}
    ]}
    """
    let runner = RecordingRunner(result: CommandResult(exitCode: 0, standardOutput: json, standardError: ""))
    let client = GitHubClient(runner: runner, ghPath: "gh")
    let ref = PRLocator(owner: "bsv-blockchain", repo: "teranode", number: 944)
    let state = try await client.fetchReviewState(for: ref, login: "ordishs")
    #expect(state.approvedByMe == false)
    #expect(state.prState == .merged)
}

@Test func fetchReviewStateThrowsOnNonZeroExit() async {
    let runner = RecordingRunner(result: CommandResult(exitCode: 1, standardOutput: "", standardError: "no pull requests found"))
    let client = GitHubClient(runner: runner, ghPath: "gh")
    let ref = PRLocator(owner: "bsv-blockchain", repo: "teranode", number: 999)
    await #expect(throws: GitHubError.self) {
        try await client.fetchReviewState(for: ref, login: "ordishs")
    }
}
