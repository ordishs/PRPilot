import Foundation

public struct GatewayIdentity: Sendable, Equatable {
    /// The tailnet login, when the proxy supplied one. Display and audit only — it is a
    /// request header, so a local process can set it to anything.
    public var login: String?

    public init(login: String?) {
        self.login = login
    }
}

/// Header keys are lowercased by the caller before they reach a verifier.
public protocol IdentityVerifier: Sendable {
    func verify(headers: [String: String]) -> GatewayIdentity?
}

/// The default.
///
/// The listener sits on loopback, where any local process can connect and set any header
/// it likes. A shared secret is the one thing a forged header cannot supply.
public struct BearerTokenVerifier: IdentityVerifier {
    private let token: String
    private let tailnetHeaderName: String

    public init(token: String, tailnetHeaderName: String = "tailscale-user-login") {
        self.token = token
        self.tailnetHeaderName = tailnetHeaderName
    }

    public func verify(headers: [String: String]) -> GatewayIdentity? {
        guard let raw = headers["authorization"] else { return nil }

        let parts = raw.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2, parts[0].lowercased() == "bearer" else { return nil }
        guard constantTimeEquals(String(parts[1]), token) else { return nil }

        return GatewayIdentity(login: headers[tailnetHeaderName])
    }

    /// Compares over the full length of both strings so a timing difference cannot leak how
    /// many leading characters of a guess were right.
    private func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let lhs = Array(a.utf8)
        let rhs = Array(b.utf8)
        var difference = lhs.count ^ rhs.count

        for index in 0..<max(lhs.count, rhs.count) {
            let l = index < lhs.count ? Int(lhs[index]) : 0
            let r = index < rhs.count ? Int(rhs[index]) : 0
            difference |= l ^ r
        }

        return difference == 0
    }
}

/// Only safe where the transport guarantees the header came from the proxy. Never the
/// default on a loopback port. Kept for a future move to a Unix socket that only
/// `tailscale serve` can open.
public struct TailnetHeaderVerifier: IdentityVerifier {
    private let headerName: String
    private let allowlist: Set<String>

    public init(headerName: String, allowlist: Set<String>) {
        self.headerName = headerName
        self.allowlist = allowlist
    }

    public func verify(headers: [String: String]) -> GatewayIdentity? {
        guard let login = headers[headerName], allowlist.contains(login) else { return nil }
        return GatewayIdentity(login: login)
    }
}
