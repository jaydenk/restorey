import Foundation
import LocalAuthentication
import Security

/// Secrets in the data protection keychain (spec §7, §10). Never drop `kSecUseDataProtectionKeychain`:
/// without it the item lands in the legacy file keychain, where `/usr/bin/security` and any
/// same-user process with the right ACL can read it, and the access group means nothing.
///
/// Proven in the platform spike (docs/spike-findings.md, H2): readable from launchd with no prompt,
/// while the screen is locked, and across a signing change. Needs the `keychain-access-groups`
/// entitlement, which in practice means running inside a signed app: bare `swift test` gets
/// -34018 (errSecMissingEntitlement).
public struct KeychainSecretStore: SecretStore {
    private let service: String
    private let accessGroup: String

    /// - Parameters:
    ///   - service: the root ID (`Identity.rootID`), so Debug and Release items never mix.
    ///   - accessGroup: `Identity.keychainAccessGroup`.
    public init(service: String, accessGroup: String) {
        self.service = service
        self.accessGroup = accessGroup
    }

    private func scopeQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccessGroup as String: accessGroup,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    private func itemQuery(account: String) -> [String: Any] {
        var query = scopeQuery()
        query[kSecAttrAccount as String] = account
        return query
    }

    public func read(_ key: SecretKey) throws -> String? {
        var query = itemQuery(account: key.account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        // Never show UI: the agent has no window to show it in.
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let data = result as? Data, let string = String(data: data, encoding: .utf8) else {
            throw SecretStoreError.undecodableValue(account: key.account)
        }
        return string
    }

    public func write(_ value: String, for key: SecretKey) throws {
        let data = Data(value.utf8)
        let query = itemQuery(account: key.account)
        let update = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            add[kSecAttrSynchronizable as String] = false
            status = SecItemAdd(add as CFDictionary, nil)
            if status == errSecDuplicateItem {
                // Another writer added it between our update and add.
                status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
            }
        }
        try check(status)
    }

    public func delete(_ key: SecretKey) throws {
        let status = SecItemDelete(itemQuery(account: key.account) as CFDictionary)
        if status == errSecItemNotFound { return }
        try check(status)
    }

    /// The keychain has no prefix query, and `SecretKey.environment` has an open-ended name, so a
    /// fixed list of known keys would leak any environment secret it forgot. Instead this lists every
    /// account under our service and access group (`kSecMatchLimitAll`) and deletes those with the
    /// plan's prefix. One query plus a delete per match; a plan has a handful of secrets.
    public func deleteAll(planID: UUID) throws {
        var query = scopeQuery()
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return }
        try check(status)
        let prefix = SecretKey.accountPrefix(planID: planID)
        let rows = result as? [[String: Any]] ?? []
        for row in rows {
            guard let account = row[kSecAttrAccount as String] as? String, account.hasPrefix(prefix) else { continue }
            let deleteStatus = SecItemDelete(itemQuery(account: account) as CFDictionary)
            if deleteStatus != errSecItemNotFound { try check(deleteStatus) }
        }
    }

    private func check(_ status: OSStatus) throws {
        guard status != errSecSuccess else { return }
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown"
        throw SecretStoreError.keychain(status: status, message: message)
    }
}
