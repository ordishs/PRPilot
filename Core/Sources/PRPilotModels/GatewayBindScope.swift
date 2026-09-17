/// Which interface the remote gateway listens on.
public enum GatewayBindScope: String, Codable, Sendable, Hashable, CaseIterable {
    /// Loopback. Nothing off this machine can connect.
    case loopback
    /// The Tailscale interface, so a reverse proxy on another tailnet node can reach it.
    case tailnet

    public var displayName: String {
        switch self {
        case .loopback: return "This Mac only"
        case .tailnet: return "Tailnet"
        }
    }
}
