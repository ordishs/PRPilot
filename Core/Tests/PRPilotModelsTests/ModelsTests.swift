import Testing
import Foundation
@testable import PRPilotModels

@Test func reviewRoundTripsThroughCodable() throws {
    let workItem = WorkItem(
        title: "centrifuge fix",
        repoKey: "github.com/bsv-blockchain/teranode",
        baseBranch: "main",
        headBranch: "fix/centrifuge",
        prRef: PRRef(
            owner: "bsv-blockchain", repo: "teranode", number: 944,
            url: URL(string: "https://github.com/bsv-blockchain/teranode/pull/944")!,
            authorLogin: "icellan"
        ),
        prState: .open,
        origin: .added,
        addedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    let data = try JSONEncoder().encode(workItem)
    let decoded = try JSONDecoder().decode(WorkItem.self, from: data)
    #expect(decoded == workItem)
}

@Test func settingsDefaultHasExpectedValues() {
    let settings = Settings.default
    #expect(settings.managedRoot.hasSuffix("PRPilot"))
    #expect(settings.reviewRequestQueries.map(\.text) == ["review-requested:@me is:open", "assignee:@me is:open"])
    #expect(settings.myPRQueries.map(\.text) == ["author:@me is:open"])
    #expect(settings.reviewRequestsEnabled == true)
    #expect(settings.myPRsEnabled == true)
    #expect(settings.pollIntervalSeconds == 120)
    #expect(settings.diffMode == .unified)
    #expect(settings.notificationsEnabled == true)
}

@Test func reviewOriginDecodesFromString() throws {
    let decoded = try JSONDecoder().decode(ReviewOrigin.self, from: Data("\"both\"".utf8))
    #expect(decoded == .both)
}

@Test func reviewEncodesAndDecodesNewStatusFields() throws {
    let workItem = WorkItem(
        title: "centrifuge fix",
        repoKey: "github.com/bsv-blockchain/teranode",
        baseBranch: "main",
        headBranch: "fix/centrifuge",
        prRef: PRRef(
            owner: "bsv-blockchain", repo: "teranode", number: 944,
            url: URL(string: "https://github.com/bsv-blockchain/teranode/pull/944")!,
            authorLogin: "icellan"
        ),
        prState: .open,
        origin: .added,
        addedAt: Date(timeIntervalSince1970: 1_700_000_000),
        claudeReviewedAt: Date(timeIntervalSince1970: 1_700_000_500),
        approvedByMe: true
    )
    let data = try JSONEncoder().encode(workItem)
    let decoded = try JSONDecoder().decode(WorkItem.self, from: data)
    #expect(decoded == workItem)
    #expect(decoded.claudeReviewedAt == Date(timeIntervalSince1970: 1_700_000_500))
    #expect(decoded.approvedByMe == true)
}

@Test func reviewDecodesLegacyJSONWithoutNewFields() throws {
    let legacy = """
    {
      "id": "bsv-blockchain/teranode#944",
      "owner": "bsv-blockchain", "repo": "teranode", "number": 944,
      "url": "https://github.com/bsv-blockchain/teranode/pull/944",
      "title": "centrifuge fix", "author": "icellan",
      "headBranch": "fix/centrifuge", "baseBranch": "main",
      "origin": "added", "prState": "open",
      "addedAt": 631152000, "disabled": false, "viewedFiles": []
    }
    """
    let decoded = try JSONDecoder().decode(WorkItem.self, from: Data(legacy.utf8))
    #expect(decoded.claudeReviewedAt == nil)
    #expect(decoded.approvedByMe == false)
}

@Test func registeredRepoRoundTripsThroughCodable() throws {
    let repo = RegisteredRepo(
        remoteIdentity: "github.com/bsv-blockchain/teranode",
        localClonePath: "/Users/me/dev/teranode",
        defaultBase: "main"
    )
    let data = try JSONEncoder().encode(repo)
    let decoded = try JSONDecoder().decode(RegisteredRepo.self, from: data)
    #expect(decoded == repo)
    #expect(decoded.id == "github.com/bsv-blockchain/teranode")
}
