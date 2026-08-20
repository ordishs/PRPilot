import Testing
import Foundation
@testable import PRPilotModels

private func encoder() -> JSONEncoder {
    let e = JSONEncoder()
    e.dateEncodingStrategy = .iso8601
    return e
}

private func decoder() -> JSONDecoder {
    let d = JSONDecoder()
    d.dateDecodingStrategy = .iso8601
    return d
}

@Test func agentRunStartedAtRoundTrips() throws {
    var item = WorkItem(
        title: "centrifuge fix",
        repoKey: "github.com/bsv-blockchain/teranode",
        baseBranch: "main",
        origin: .added,
        addedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    item.agentRunStartedAt = Date(timeIntervalSince1970: 1_755_000_000)
    let data = try encoder().encode(item)
    let decoded = try decoder().decode(WorkItem.self, from: data)
    #expect(decoded.agentRunStartedAt == item.agentRunStartedAt)
}

@Test func agentRunStartedAtDefaultsToNil() {
    let item = WorkItem(
        title: "centrifuge fix",
        repoKey: "github.com/bsv-blockchain/teranode",
        baseBranch: "main",
        origin: .added,
        addedAt: Date()
    )
    #expect(item.agentRunStartedAt == nil)
}

@Test func storedItemWithoutTheKeyStillDecodes() throws {
    // An item written before the field existed must load, with the run start absent.
    let json = """
    {
      "id": "6E1F2A54-0000-0000-0000-000000000000",
      "title": "centrifuge fix",
      "repoKey": "github.com/bsv-blockchain/teranode",
      "baseBranch": "main",
      "origin": "added",
      "addedAt": "2026-08-19T14:32:00Z",
      "disabled": false,
      "viewedFiles": [],
      "autoReview": false,
      "approvedByMe": false
    }
    """
    let item = try decoder().decode(WorkItem.self, from: Data(json.utf8))
    #expect(item.agentRunStartedAt == nil)
    #expect(item.title == "centrifuge fix")
}
