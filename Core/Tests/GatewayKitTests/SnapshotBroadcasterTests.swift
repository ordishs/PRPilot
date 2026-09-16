import Testing
import Foundation
@testable import GatewayKit

/// Returns nil when the operation did not finish in time, so a test can assert that nothing
/// arrived without hanging the suite.
private func withTimeout<T: Sendable>(
    milliseconds: Int,
    _ operation: @escaping @Sendable () async -> T
) async throws -> T? {
    try await withThrowingTaskGroup(of: T?.self) { group in
        group.addTask { await operation() }
        group.addTask {
            try await Task.sleep(for: .milliseconds(milliseconds))
            return nil
        }
        let first = try await group.next()
        group.cancelAll()
        return first ?? nil
    }
}

@Test func theFirstEventASubscriberReceivesIsTheCurrentSnapshot() async throws {
    let backend = await FakeGatewayBackend()
    let broadcaster = SnapshotBroadcaster(backend: backend, interval: .milliseconds(20))

    let stream = await broadcaster.subscribe()
    var iterator = stream.makeAsyncIterator()
    let first = await iterator.next()

    #expect(first?.login == "ordishs")
    await broadcaster.shutdown()
}

@Test func anUnchangedSnapshotProducesNoFurtherEvent() async throws {
    let backend = await FakeGatewayBackend()
    let broadcaster = SnapshotBroadcaster(backend: backend, interval: .milliseconds(20))

    let stream = await broadcaster.subscribe()
    let iterator = UncheckedBox(stream.makeAsyncIterator())
    _ = await iterator.next()

    let second = try await withTimeout(milliseconds: 250) { await iterator.next() }
    #expect(second == nil, "an unchanged snapshot must not be re-sent")

    await broadcaster.shutdown()
}

@Test func aChangedSnapshotProducesAnEvent() async throws {
    let backend = await FakeGatewayBackend()
    let broadcaster = SnapshotBroadcaster(backend: backend, interval: .milliseconds(20))

    let stream = await broadcaster.subscribe()
    let iterator = UncheckedBox(stream.makeAsyncIterator())
    _ = await iterator.next()

    await MainActor.run { backend.login = "someone-else" }

    let second = try await withTimeout(milliseconds: 3000) { await iterator.next() }
    #expect(second??.login == "someone-else")

    await broadcaster.shutdown()
}

@Test func aPokeDeliversTheChangeWithoutWaitingOutTheInterval() async throws {
    let backend = await FakeGatewayBackend()
    let broadcaster = SnapshotBroadcaster(backend: backend, interval: .seconds(3600))

    let stream = await broadcaster.subscribe()
    let iterator = UncheckedBox(stream.makeAsyncIterator())
    _ = await iterator.next()

    await MainActor.run { backend.login = "poked" }
    broadcaster.poke()

    let second = try await withTimeout(milliseconds: 2000) { await iterator.next() }
    #expect(second??.login == "poked")

    await broadcaster.shutdown()
}

@Test func thePollerStopsAfterTheLastSubscriberGoesAway() async throws {
    let backend = await FakeGatewayBackend()
    let broadcaster = SnapshotBroadcaster(backend: backend, interval: .milliseconds(20))

    do {
        let stream = await broadcaster.subscribe()
        var iterator = stream.makeAsyncIterator()
        _ = await iterator.next()
        #expect(await broadcaster.isPolling)
    }

    try await Task.sleep(for: .milliseconds(400))

    #expect(await broadcaster.subscriberCount == 0)
    #expect(await broadcaster.isPolling == false)
}

/// `AsyncStream.Iterator` is not `Sendable`, but a single test drives it from one task at a
/// time. The box carries it across the timeout helper's task boundary.
private final class UncheckedBox<Element>: @unchecked Sendable {
    private var iterator: AsyncStream<Element>.Iterator

    init(_ iterator: AsyncStream<Element>.Iterator) {
        self.iterator = iterator
    }

    func next() async -> Element? {
        await iterator.next()
    }
}
