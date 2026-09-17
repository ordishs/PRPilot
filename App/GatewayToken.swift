import Foundation
import Security

/// The gateway's shared secret, kept in the Keychain.
///
/// The listener sits on loopback, where any local process can connect and forge any header
/// it likes. The token is the one thing such a process cannot supply, so it is the whole of
/// the gateway's authentication.
enum GatewayToken {
    private static let service = "com.ordishs.PRPilot.gateway"
    private static let account = "bearer"

    static func loadOrCreate() -> String {
        if let existing = load() {
            return existing
        }
        let fresh = generate()
        store(fresh)
        return fresh
    }

    /// Replaces the stored token. Every installed client must be re-paired afterwards.
    @discardableResult
    static func regenerate() -> String {
        let fresh = generate()
        delete()
        store(fresh)
        return fresh
    }

    private static func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let token = String(data: data, encoding: .utf8),
              !token.isEmpty
        else {
            return nil
        }
        return token
    }

    private static func store(_ token: String) {
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(token.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
        ]
        SecItemAdd(attributes as CFDictionary, nil)
    }

    private static func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// 32 bytes of system randomness, base64url so it survives a query string and a QR code
    /// without escaping.
    private static func generate() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed with \(status)")

        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
