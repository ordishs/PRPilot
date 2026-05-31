import Testing
import Foundation
@testable import PRPilotModels

@Test func reviewIDIsOwnerRepoNumber() {
    #expect(Review.makeID(owner: "bsv-blockchain", repo: "teranode", number: 944) == "bsv-blockchain/teranode#944")
}

@Test func reviewRoundTripsThroughCodable() throws {
    let review = Review(
        owner: "bsv-blockchain",
        repo: "teranode",
        number: 944,
        url: URL(string: "https://github.com/bsv-blockchain/teranode/pull/944")!,
        title: "centrifuge fix",
        author: "icellan",
        headBranch: "fix/centrifuge",
        baseBranch: "main",
        origin: .added,
        prState: .open,
        addedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    let data = try JSONEncoder().encode(review)
    let decoded = try JSONDecoder().decode(Review.self, from: data)
    #expect(decoded == review)
    #expect(decoded.id == "bsv-blockchain/teranode#944")
}

@Test func settingsDefaultHasExpectedValues() {
    let settings = Settings.default
    #expect(settings.managedRoot.hasSuffix("PRPilot"))
    #expect(settings.discoveryQueries == ["review-requested:@me is:open", "assignee:@me is:open"])
    #expect(settings.pollIntervalSeconds == 120)
    #expect(settings.diffMode == .unified)
    #expect(settings.notificationsEnabled == true)
}

@Test func reviewOriginDecodesFromString() throws {
    let decoded = try JSONDecoder().decode(ReviewOrigin.self, from: Data("\"both\"".utf8))
    #expect(decoded == .both)
}

@Test func reviewEncodesAndDecodesNewStatusFields() throws {
    let review = Review(
        owner: "bsv-blockchain", repo: "teranode", number: 944,
        url: URL(string: "https://github.com/bsv-blockchain/teranode/pull/944")!,
        title: "centrifuge fix", author: "icellan",
        headBranch: "fix/centrifuge", baseBranch: "main",
        origin: .added, prState: .open,
        addedAt: Date(timeIntervalSince1970: 1_700_000_000),
        claudeReviewedAt: Date(timeIntervalSince1970: 1_700_000_500),
        approvedByMe: true
    )
    let data = try JSONEncoder().encode(review)
    let decoded = try JSONDecoder().decode(Review.self, from: data)
    #expect(decoded == review)
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
    let decoded = try JSONDecoder().decode(Review.self, from: Data(legacy.utf8))
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
