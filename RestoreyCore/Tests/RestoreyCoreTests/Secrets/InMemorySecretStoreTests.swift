import Foundation
import Testing
@testable import RestoreyCore

@Suite struct InMemorySecretStoreTests {
    @Test func accountNames() {
        let id = UUID()
        #expect(SecretKey.repositoryPassword(id).account == "plan.\(id.uuidString).repository-password")
        #expect(SecretKey.s3AccessKeyID(id).account == "plan.\(id.uuidString).s3-access-key-id")
        #expect(SecretKey.s3SecretAccessKey(id).account == "plan.\(id.uuidString).s3-secret-access-key")
        #expect(SecretKey.environment(id, name: "FOO").account == "plan.\(id.uuidString).environment.FOO")
        #expect(SecretKey.checkInURL(id).account == "plan.\(id.uuidString).check-in-url")
    }

    @Test func roundTripAndMissing() throws {
        let store = InMemorySecretStore()
        let key = SecretKey.repositoryPassword(UUID())
        #expect(try store.read(key) == nil)
        try store.write("one", for: key)
        try store.write("two", for: key)
        #expect(try store.read(key) == "two")
        try store.delete(key)
        try store.delete(key)
        #expect(try store.read(key) == nil)
    }

    @Test func deleteAllRemovesOnlyThatPlan() throws {
        let store = InMemorySecretStore()
        let a = UUID(), b = UUID()
        try store.write("1", for: .repositoryPassword(a))
        try store.write("2", for: .environment(a, name: "X"))
        try store.write("3", for: .checkInURL(a))
        try store.write("4", for: .repositoryPassword(b))
        try store.deleteAll(planID: a)
        #expect(try store.read(.repositoryPassword(a)) == nil)
        #expect(try store.read(.environment(a, name: "X")) == nil)
        #expect(try store.read(.checkInURL(a)) == nil)
        #expect(try store.read(.repositoryPassword(b)) == "4")
    }
}
