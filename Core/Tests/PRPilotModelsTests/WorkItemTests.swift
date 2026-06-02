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
