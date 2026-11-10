import Foundation
import Security
import Testing
import RestoreyCore

/// Runs inside the signed agent app, so it has the `keychain-access-groups` entitlement that bare
/// `swift test` lacks (-34018). Every test uses a fresh random plan ID and removes what it made, so
/// it never touches a real Restorey item.
@Suite struct KeychainSecretStoreTests {
    private static func store() throws -> (KeychainSecretStore, Identity) {
        let identity = try Identity.fromBundle(.main)
        return (KeychainSecretStore(service: identity.rootID, accessGroup: identity.keychainAccessGroup), identity)
    }

    @Test func roundTripPreservesExactBytes() throws {
        let (store, _) = try Self.store()
        let plan = UUID()
        defer { try? store.deleteAll(planID: plan) }
        let value = "pa ss\"wörd\n"
        try store.write(value, for: .repositoryPassword(plan))
        #expect(try store.read(.repositoryPassword(plan)) == value)
        // Writing again replaces rather than failing with errSecDuplicateItem.
        try store.write("second", for: .repositoryPassword(plan))
        #expect(try store.read(.repositoryPassword(plan)) == "second")
        try store.delete(.repositoryPassword(plan))
        #expect(try store.read(.repositoryPassword(plan)) == nil)
    }

    @Test func itemIsInDataProtectionKeychain() throws {
        let (store, identity) = try Self.store()
        let plan = UUID()
        defer { try? store.deleteAll(planID: plan) }
        let key = SecretKey.repositoryPassword(plan)
        try store.write("secret", for: key)

        // An unqualified query inside a signed app searches both keychains, so the negative control
        // has to say `false` explicitly to look at the legacy file keychain only.
        func find(dataProtection: Bool) -> OSStatus {
            var query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: identity.rootID,
                kSecAttrAccount as String: key.account,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            query[kSecUseDataProtectionKeychain as String] = dataProtection
            return SecItemCopyMatching(query as CFDictionary, nil)
        }
        #expect(find(dataProtection: true) == errSecSuccess)
        #expect(find(dataProtection: false) == errSecItemNotFound)
    }

    @Test func deleteAllRemovesOnlyThatPlan() throws {
        let (store, _) = try Self.store()
        let a = UUID(), b = UUID()
        defer { try? store.deleteAll(planID: a); try? store.deleteAll(planID: b) }
        try store.write("1", for: .repositoryPassword(a))
        try store.write("2", for: .environment(a, name: "ANY_NAME"))
        try store.write("3", for: .checkInURL(a))
        try store.write("4", for: .repositoryPassword(b))
        try store.deleteAll(planID: a)
        #expect(try store.read(.repositoryPassword(a)) == nil)
        #expect(try store.read(.environment(a, name: "ANY_NAME")) == nil)
        #expect(try store.read(.checkInURL(a)) == nil)
        #expect(try store.read(.repositoryPassword(b)) == "4")
    }

    @Test func missingItemReadsAsNilAndDeleteIsQuiet() throws {
        let (store, _) = try Self.store()
        let key = SecretKey.s3SecretAccessKey(UUID())
        #expect(try store.read(key) == nil)
        try store.delete(key)
    }

    @Test func wrongAccessGroupThrowsWithStatusAndMessage() throws {
        let (_, identity) = try Self.store()
        let bad = KeychainSecretStore(service: identity.rootID, accessGroup: "X72LEXP4DY.com.example.not-ours")
        do {
            _ = try bad.read(.repositoryPassword(UUID()))
            Issue.record("expected a keychain error for a group the host does not hold")
        } catch let SecretStoreError.keychain(status, message) {
            #expect(status != 0)
            #expect(!message.isEmpty)
        }
    }
}
