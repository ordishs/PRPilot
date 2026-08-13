import Testing
import Foundation
@testable import PRPilotModels

@Test func prRefRoundTripsThroughCodable() throws {
    let ref = PRRef(
        owner: "bsv-blockchain",
        repo: "teranode",
        number: 944,
        url: URL(string: "https://github.com/bsv-blockchain/teranode/pull/944")!,
        authorLogin: "icellan"
    )
    let data = try JSONEncoder().encode(ref)
    let decoded = try JSONDecoder().decode(PRRef.self, from: data)
    #expect(decoded == ref)
    #expect(decoded.authorLogin == "icellan")
}

private func prItem(
    authorLogin: String = "icellan",
    prState: PRState? = .open
) -> WorkItem {
    WorkItem(
        id: "11111111-1111-1111-1111-111111111111",
        title: "centrifuge fix",
        repoKey: "github.com/bsv-blockchain/teranode",
        baseBranch: "main",
        headBranch: "fix/centrifuge",
        prRef: PRRef(
            owner: "bsv-blockchain", repo: "teranode", number: 944,
            url: URL(string: "https://github.com/bsv-blockchain/teranode/pull/944")!,
            authorLogin: authorLogin
        ),
        prState: prState,
        origin: .added,
        addedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
}

@Test func workItemDerivesOwnerAndRepoFromRepoKey() {
    let item = prItem()
    #expect(item.owner == "bsv-blockchain")
    #expect(item.repo == "teranode")
    #expect(item.number == 944)
    #expect(item.author == "icellan")
}

@Test func workItemWithoutPRIsATask() {
    let task = WorkItem(
        id: "t", title: "spike", repoKey: "github.com/bsv-blockchain/teranode",
        baseBranch: "main", headBranch: "feat/spike", prRef: nil, prState: nil,
        origin: .added, addedAt: Date(timeIntervalSince1970: 0)
    )
    #expect(task.category(myLogin: "ordishs") == .task)
    #expect(task.number == nil)
    #expect(task.author == nil)
}

@Test func workItemAuthoredByMeIsMyPR() {
    #expect(prItem(authorLogin: "ordishs").category(myLogin: "ordishs") == .myPR)
}

@Test func workItemAuthoredByMeIsCaseInsensitive() {
    #expect(prItem(authorLogin: "OrDishS").category(myLogin: "ordishs") == .myPR)
}

@Test func workItemAuthoredByOtherIsReviewRequest() {
    #expect(prItem(authorLogin: "icellan").category(myLogin: "ordishs") == .reviewRequest)
}

@Test func workItemWithUnknownMyLoginIsReviewRequest() {
    #expect(prItem(authorLogin: "icellan").category(myLogin: nil) == .reviewRequest)
}

@Test func workItemRoundTripsThroughCodableInNewShape() throws {
    let item = prItem()
    let data = try JSONEncoder().encode(item)
    let decoded = try JSONDecoder().decode(WorkItem.self, from: data)
    #expect(decoded == item)
    #expect(decoded.id == "11111111-1111-1111-1111-111111111111")
    #expect(decoded.prRef?.number == 944)
}

private func sampleIssue() -> WorkItem {
    WorkItem(
        title: "Login crashes on empty password",
        repoKey: "github.com/bsv-blockchain/teranode",
        baseBranch: "main",
        headBranch: "issue-42-login-crashes-on-empty-password",
        issueRef: IssueRef(
            owner: "bsv-blockchain", repo: "teranode", number: 42,
            url: URL(string: "https://github.com/bsv-blockchain/teranode/issues/42")!,
            authorLogin: "alice"
        ),
        prState: .open,
        origin: .discovered,
        addedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
}

@Test func issueItemCategoryIsIssue() {
    #expect(sampleIssue().category(myLogin: "ordishs") == .issue)
    #expect(sampleIssue().category(myLogin: nil) == .issue)
}

@Test func issueItemAccessors() {
    let item = sampleIssue()
    #expect(item.number == nil)
    #expect(item.issueNumber == 42)
    #expect(item.displayNumber == 42)
    #expect(item.url?.absoluteString == "https://github.com/bsv-blockchain/teranode/issues/42")
    #expect(item.author == "alice")
}

@Test func issueBranchNameSlugsTitle() {
    #expect(WorkItem.issueBranchName(number: 42, title: "Login crashes on empty password!")
        == "issue-42-login-crashes-on-empty-password")
    #expect(WorkItem.issueBranchName(number: 7, title: "   ")
        == "issue-7")
    let long = WorkItem.issueBranchName(number: 9, title: String(repeating: "ab cd ", count: 20))
    #expect(long.hasPrefix("issue-9-"))
    #expect(!long.hasSuffix("-"))
}

@Test func issueItemCodableRoundTrips() throws {
    let item = sampleIssue()
    let data = try JSONEncoder().encode(item)
    let decoded = try JSONDecoder().decode(WorkItem.self, from: data)
    #expect(decoded == item)
    #expect(decoded.issueRef?.number == 42)
}

@Test func manualIssueStatusRoundTrips() throws {
    var item = sampleIssue()
    item.manualIssueStatus = .onHold
    let data = try JSONEncoder().encode(item)
    let decoded = try JSONDecoder().decode(WorkItem.self, from: data)
    #expect(decoded.manualIssueStatus == .onHold)
}

@Test func legacyItemDecodesWithNilManualIssueStatus() throws {
    let json = """
    {
      "id": "X", "title": "t", "repoKey": "github.com/o/r",
      "baseBranch": "main", "origin": "added", "autoReview": false,
      "addedAt": "2023-11-14T22:13:20Z", "disabled": false, "viewedFiles": [], "approvedByMe": false
    }
    """
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(WorkItem.self, from: Data(json.utf8))
    #expect(decoded.manualIssueStatus == nil)
}

@Test func legacyItemWithoutIssueRefDecodes() throws {
    let json = """
    {
      "id": "X", "title": "centrifuge fix", "repoKey": "github.com/bsv-blockchain/teranode",
      "baseBranch": "main", "origin": "added", "autoReview": false,
      "addedAt": "2023-11-14T22:13:20Z", "disabled": false, "viewedFiles": [], "approvedByMe": false
    }
    """
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(WorkItem.self, from: Data(json.utf8))
    #expect(decoded.issueRef == nil)
    #expect(decoded.category(myLogin: nil) == .task)
}

@Test func labelAndLastPaneRoundTrip() throws {
    var item = sampleIssue()
    item.label = "Blocks the mainnet upgrade"
    item.lastPane = .claude
    let data = try JSONEncoder().encode(item)
    let decoded = try JSONDecoder().decode(WorkItem.self, from: data)
    #expect(decoded.label == "Blocks the mainnet upgrade")
    #expect(decoded.lastPane == .claude)
    #expect(decoded == item)
}

@Test func legacyItemDecodesWithNilLabelAndLastPane() throws {
    let json = """
    {
      "id": "X", "title": "t", "repoKey": "github.com/o/r",
      "baseBranch": "main", "origin": "added", "autoReview": false,
      "addedAt": "2023-11-14T22:13:20Z", "disabled": false, "viewedFiles": [], "approvedByMe": false
    }
    """
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(WorkItem.self, from: Data(json.utf8))
    #expect(decoded.label == nil)
    #expect(decoded.lastPane == nil)
}

@Test func resolvedPaneRestoresRememberedChoiceOverTypeDefault() {
    var pr = prItem()
    pr.lastPane = .claude
    #expect(resolvedPane(for: pr) == .claude)

    var task = WorkItem(
        id: "t", title: "spike", repoKey: "github.com/bsv-blockchain/teranode",
        baseBranch: "main", origin: .added, addedAt: Date(timeIntervalSince1970: 0)
    )
    task.lastPane = .github
    #expect(resolvedPane(for: task) == .github)
}

@Test func resolvedPaneFallsBackToTypeDefaultOnFirstVisit() {
    #expect(prItem().lastPane == nil)
    #expect(resolvedPane(for: prItem()) == .github)

    let task = WorkItem(
        id: "t", title: "spike", repoKey: "github.com/bsv-blockchain/teranode",
        baseBranch: "main", origin: .added, addedAt: Date(timeIntervalSince1970: 0)
    )
    #expect(resolvedPane(for: task) == .claude)

    let issue = sampleIssue()
    #expect(issue.prRef == nil && issue.issueRef != nil)
    #expect(resolvedPane(for: issue) == .github)
}

@Test func resolvedPanePinsDisabledItemToGitHubWithoutLosingMemory() {
    var pr = prItem()
    pr.lastPane = .claude
    pr.disabled = true
    #expect(resolvedPane(for: pr) == .github)
    // The remembered choice survives so re-enabling restores it.
    #expect(pr.lastPane == .claude)
    pr.disabled = false
    #expect(resolvedPane(for: pr) == .claude)
}

@Test func resolvedPaneIsIndependentPerItem() {
    var a = prItem()
    a.lastPane = .claude
    var b = prItem()
    b.lastPane = .github
    #expect(resolvedPane(for: a) == .claude)
    #expect(resolvedPane(for: b) == .github)
}

@Test func paneSelectionEncodesStableRawValues() throws {
    #expect(PaneSelection.claude.rawValue == "claude")
    #expect(PaneSelection.github.rawValue == "github")
    // The raw value stays "claude" because it is persisted, but the label follows the agent
    // actually driving the item.
    #expect(PaneSelection.claude.displayName(for: .claudeCode) == "Claude Code Review")
    #expect(PaneSelection.claude.displayName(for: .pi) == "pi Review")
    #expect(PaneSelection.github.displayName(for: .claudeCode) == "GitHub")
    #expect(PaneSelection.github.displayName(for: .pi) == "GitHub")
    #expect(PaneSelection.allCases == [.claude, .github])
    let decoded = try JSONDecoder().decode(PaneSelection.self, from: Data("\"github\"".utf8))
    #expect(decoded == .github)
}

@Test func workItemWithoutTheNewReviewFieldsDecodesWithNils() throws {
    let json = """
    {
      "id": "abc",
      "title": "t",
      "repoKey": "github.com/o/r",
      "baseBranch": "main",
      "origin": "added",
      "addedAt": "2026-08-01T10:00:00Z",
      "disabled": false,
      "viewedFiles": [],
      "approvedByMe": false,
      "autoReview": false
    }
    """
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    let item = try decoder.decode(WorkItem.self, from: Data(json.utf8))

    #expect(item.myReviewState == nil)
    #expect(item.myLastReviewAt == nil)
    #expect(item.claudeLastCompletedAt == nil)
}

@Test func workItemRoundTripsTheNewReviewFields() throws {
    var item = WorkItem(
        title: "t",
        repoKey: "github.com/o/r",
        baseBranch: "main",
        origin: .added,
        addedAt: Date(timeIntervalSince1970: 0)
    )
    item.myReviewState = .changesRequested
    item.myLastReviewAt = Date(timeIntervalSince1970: 500)
    item.claudeLastCompletedAt = Date(timeIntervalSince1970: 900)

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(WorkItem.self, from: encoder.encode(item))

    #expect(decoded.myReviewState == .changesRequested)
    #expect(decoded.myLastReviewAt == Date(timeIntervalSince1970: 500))
    #expect(decoded.claudeLastCompletedAt == Date(timeIntervalSince1970: 900))
}
