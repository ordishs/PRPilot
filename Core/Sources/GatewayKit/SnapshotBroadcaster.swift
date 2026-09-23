import Foundation

/// Watches the backend and pushes a snapshot to every subscriber when it changes.
///
/// `@Observable` tracking is one-shot, and a missed re-registration stalls a long-lived
/// stream silently. A poller cannot miss an update, and it needs no change to `AppModel`.
/// The cost is up to one interval of latency and one wake-up per interval while a client is
/// connected. The poller runs only while somebody is listening.
public actor SnapshotBroadcaster {
    private let backend: any GatewayBackend
    private let interval: Duration
    private var continuations: [UUID: AsyncStream<GatewaySnapshot>.Continuation] = [:]
    private var lastHash: Int?
    private var pollTask: Task<Void, Never>?

    public init(backend: any GatewayBackend, interval: Duration = .seconds(1)) {
        self.backend = backend
        self.interval = interval
    }

    public var subscriberCount: Int { continuations.count }
    public var isPolling: Bool { pollTask != nil }

    public func subscribe() async -> AsyncStream<GatewaySnapshot> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<GatewaySnapshot>.makeStream()
        continuations[id] = continuation

        continuation.onTermination = { [weak self] _ in
            Task { await self?.unsubscribe(id) }
        }

        let current = await MainActor.run { backend.snapshot() }
        lastHash = fingerprint(of: current)
        continuation.yield(current)

        startPollingIfNeeded()
        return stream
    }

    /// Called right after a command runs, so every other client sees the effect at once
    /// instead of waiting out the interval.
    public nonisolated func poke() {
        Task { await self.tick() }
    }

    public func shutdown() {
        pollTask?.cancel()
        pollTask = nil
        for continuation in continuations.values {
            continuation.finish()
        }
        continuations.removeAll()
        lastHash = nil
    }

    private func unsubscribe(_ id: UUID) {
        continuations.removeValue(forKey: id)
        if continuations.isEmpty {
            pollTask?.cancel()
            pollTask = nil
            lastHash = nil
        }
    }

    private func startPollingIfNeeded() {
        guard pollTask == nil else { return }
        pollTask = Task { [interval] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                if Task.isCancelled { return }
                await self.tick()
            }
        }
    }

    private func tick() async {
        guard !continuations.isEmpty else { return }

        let snapshot = await MainActor.run { backend.snapshot() }
        let hash = fingerprint(of: snapshot)
        guard hash != lastHash else { return }

        lastHash = hash
        for continuation in continuations.values {
            continuation.yield(snapshot)
        }
    }

    /// `generatedAt` changes on every read, so hashing the whole snapshot would report a
    /// change every tick. The fingerprint covers everything the client renders and nothing
    /// that is merely a timestamp of the read itself.
    private func fingerprint(of snapshot: GatewaySnapshot) -> Int {
        var hasher = Hasher()
        hasher.combine(snapshot.login)
        hasher.combine(snapshot.appVersion)
        hasher.combine(snapshot.warnings)
        hasher.combine(snapshot.listing.sort)
        hasher.combine(snapshot.listing.hideParked)
        hasher.combine(snapshot.listing.signalFilters)
        hasher.combine(snapshot.listing.resourceFilters)
        hasher.combine(snapshot.listing.sorts)

        for section in snapshot.sections {
            hasher.combine(section.kind)
            for item in section.items {
                hasher.combine(item)
            }
        }

        return hasher.finalize()
    }
}
