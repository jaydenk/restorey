import Foundation
import LocalAuthentication
import Security

/// Data protection keychain only (spec §7, §10). Never drop kSecUseDataProtectionKeychain.
enum SpikeKeychain {
    /// `$(AppIdentifierPrefix)com.jaydenkerr.restorey.spike`, expanded into Info.plist at build time.
    static var accessGroup: String {
        Bundle.main.object(forInfoDictionaryKey: "SpikeKeychainAccessGroup") as? String ?? "missing"
    }

    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: SpikeIDs.keychainService,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: accessGroup,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    static func store(_ secret: String, account: String) -> OSStatus {
        _ = delete(account: account)
        var query = baseQuery(account: account)
        query[kSecValueData as String] = Data(secret.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(query as CFDictionary, nil)
    }

    static func read(account: String) -> (String?, OSStatus) {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        // Never show UI: the agent has no window to show it in.
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return (nil, status) }
        return (String(data: data, encoding: .utf8), status)
    }

    static func delete(account: String) -> OSStatus {
        SecItemDelete(baseQuery(account: account) as CFDictionary)
    }

    static func describe(_ status: OSStatus) -> String {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown"
        return "\(status) (\(message))"
    }

    static func randomSecret() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
    }
}
