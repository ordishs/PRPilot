import Foundation
import Hummingbird

/// Owns the listener, the broadcaster and the ledger for one run of the gateway.
@MainActor
public final class GatewayService {
    private let backend: any GatewayBackend
    public let host: String
    public let port: Int
    private let token: String
    private let appVersion: String
    private let webRoot: URL?
    private let broadcaster: SnapshotBroadcaster
    private let ledger = CommandLedger()
    private var runTask: Task<Void, Never>?

    public init(
        backend: any GatewayBackend,
        host: String = TailnetAddress.loopback,
        port: Int,
        token: String,
        appVersion: String,
        webRoot: URL? = nil
    ) {
        self.backend = backend
        self.host = host
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

    /// Where a reverse proxy on another tailnet node should point.
    public var proxyTarget: String { "http://\(host):\(port)" }

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

        // The operating system enforces the boundary. Loopback means nothing off this
        // machine can connect at all; a tailnet address means only tailnet peers can.
        // Neither is ever a wildcard — see `TailnetAddress.bindAddress(for:)`.
        let app = Application(
            router: router,
            configuration: .init(address: .hostname(host, port: port))
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
