import Testing
import Foundation
@testable import GatewayKit

private func result(_ message: String) -> GatewayCommandResult {
    GatewayCommandResult(
        status: .accepted,
        message: message,
        snapshot: GatewaySnapshot(
            generatedAt: Date(timeIntervalSince1970: 0),
            appVersion: "test",
            login: nil,
            sections: [],
            warnings: []
        )
    )
}

@Test func anUnknownCommandIdHasNoRecordedResult() async {
    let ledger = CommandLedger(capacity: 4)

    #expect(await ledger.result(for: "never-seen") == nil)
}

@Test func aRecordedResultComesBackForTheSameCommandId() async {
    let ledger = CommandLedger(capacity: 4)
    await ledger.record(result("first"), for: "c-1")

    #expect(await ledger.result(for: "c-1")?.message == "first")
}

@Test func theOldestEntryIsEvictedOnceCapacityIsReached() async {
    let ledger = CommandLedger(capacity: 2)
    await ledger.record(result("one"), for: "c-1")
    await ledger.record(result("two"), for: "c-2")
    await ledger.record(result("three"), for: "c-3")

    #expect(await ledger.result(for: "c-1") == nil)
    #expect(await ledger.result(for: "c-2")?.message == "two")
    #expect(await ledger.result(for: "c-3")?.message == "three")
}

@Test func rerecordingTheSameIdReplacesTheResultWithoutGrowing() async {
    let ledger = CommandLedger(capacity: 2)
    await ledger.record(result("one"), for: "c-1")
    await ledger.record(result("one-again"), for: "c-1")
    await ledger.record(result("two"), for: "c-2")

    #expect(await ledger.result(for: "c-1")?.message == "one-again")
    #expect(await ledger.result(for: "c-2")?.message == "two")
}
