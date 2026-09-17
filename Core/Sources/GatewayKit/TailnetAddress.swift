import Foundation
import PRPilotModels

#if canImport(Darwin)
import Darwin
#endif

public enum TailnetAddress {
    public static let loopback = "127.0.0.1"

    /// Tailscale assigns every node an IPv4 address in 100.64.0.0/10, the carrier-grade NAT
    /// range reserved by RFC 6598. Matching the range rather than the interface name means
    /// this does not depend on the `tailscale` binary being installed or on PATH.
    public static func isTailscale(_ address: String) -> Bool {
        let parts = address.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }

        var octets: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.count <= 3, part.allSatisfy(\.isNumber),
                  let value = Int(part), value >= 0, value <= 255
            else {
                return false
            }
            octets.append(value)
        }

        // 100.64.0.0/10 spans 100.64.0.0 through 100.127.255.255.
        return octets[0] == 100 && (64...127).contains(octets[1])
    }

    /// This node's Tailscale IPv4 address, or nil when Tailscale is not up.
    public static func current() -> String? {
        #if canImport(Darwin)
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }

        var found: String?
        for interface in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let addr = interface.pointee.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_INET),
                  interface.pointee.ifa_flags & UInt32(IFF_UP) != 0
            else {
                continue
            }

            var buffer = [UInt8](repeating: 0, count: Int(NI_MAXHOST))
            let resolved = buffer.withUnsafeMutableBufferPointer { raw -> Int32 in
                raw.baseAddress!.withMemoryRebound(to: CChar.self, capacity: raw.count) { text in
                    getnameinfo(
                        addr,
                        socklen_t(addr.pointee.sa_len),
                        text,
                        socklen_t(raw.count),
                        nil,
                        0,
                        NI_NUMERICHOST
                    )
                }
            }
            guard resolved == 0 else { continue }

            let address = String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
            if isTailscale(address) {
                found = address
                break
            }
        }
        return found
        #else
        return nil
        #endif
    }

    /// The address to bind for a scope.
    ///
    /// A `.tailnet` scope with Tailscale down falls back to loopback rather than failing to
    /// start. A gateway nobody can reach is a nuisance; one that silently binds a wider
    /// interface than asked would be a defect.
    public static func bindAddress(for scope: GatewayBindScope) -> String {
        switch scope {
        case .loopback: return loopback
        case .tailnet: return current() ?? loopback
        }
    }
}
