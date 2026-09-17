import Foundation
import Hummingbird

/// Owns the listener, the broadcaster and the ledger for one run of the gateway.
@MainActor
public final class GatewayService {
    private let backend: any GatewayBackend
    public let port: Int
    private let token: String
    private let appVersion: String
    private let webRoot: URL?
    private let broadcaster: SnapshotBroadcaster
    private let ledger = CommandLedger()
    private var runTask: Task<Void, Never>?

    public init(
        backend: any GatewayBackend,
        port: Int,
        token: String,
        appVersion: String,
        webRoot: URL? = nil
    ) {
        self.backend = backend
        self.port = port
        self.token = token
        self.appVersion = appVersion
        self.webRoot = webRoot
        self.broadcaster = SnapshotBroadcaster(backend: backend)
    }

    public var isRunning: Bool { runTask != nil }

    /// The command the user pastes to publish the gateway on their tailnet. Shown in
    /// Settings rather than run for them, because it changes their tailnet configuration.
    public var tailscaleCommand: String { "tailscale serve --bg \(port)" }

    public func start() {
        guard runTask == nil else { return }

        let router = GatewayRouter.make(
            backend: backend,
            verifier: BearerTokenVerifier(token: token),
            ledger: ledger,
            appVersion: appVersion,
            broadcaster: broadcaster,
            webRoot: webRoot
        )

        // Loopback only. The operating system then guarantees that nothing off this machine
        // can reach the listener, and `tailscale serve` is the only intended local client.
        let app = Application(
            router: router,
            configuration: .init(address: .hostname("127.0.0.1", port: port))
        )

        runTask = Task {
            do {
                try await app.runService()
            } catch {
                // A cancelled run is the normal stop path.
            }
        }
    }

    public func stop() {
        runTask?.cancel()
        runTask = nil
        Task { [broadcaster] in await broadcaster.shutdown() }
    }
}
