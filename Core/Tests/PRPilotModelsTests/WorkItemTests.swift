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
