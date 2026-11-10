import Foundation
import Synchronization
import Testing
@testable import AgentCore
import RestoreyCore

/// What the agent replies to `print-password` and `s3-credentials`, without XPC.
struct HelperResponderTests {
    private static let caller: pid_t = 4242
    private static let restic: pid_t = 4243
    private static let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)

    /// Counts reads, so a test can show a refused request never touched the keychain.
    final class CountingSecretStore: SecretStore {
        struct Failure: Error, CustomStringConvertible { var description: String { "keychain error -25308" } }
        let inner = InMemorySecretStore()
        let reads = Mutex(0)
        let failReads = Mutex(false)

        func read(_ key: SecretKey) throws -> String? {
            reads.withLock { $0 += 1 }
            if failReads.withLock({ $0 }) { throw Failure() }
            return try inner.read(key)
        }
        func write(_ value: String, for key: SecretKey) throws { try inner.write(value, for: key) }
        func delete(_ key: SecretKey) throws { try inner.delete(key) }
        func deleteAll(planID: UUID) throws { try inner.deleteAll(planID: planID) }
    }

    final class Fixture: Sendable {
        let directory: URL
        let secrets = CountingSecretStore()
        let supervised = SupervisedProcesses()
        let state: AgentState
        let planID = UUID()

        init(secrets entries: [SecretKey: String]? = nil) async throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("restorey-helper-\(UUID().uuidString)", isDirectory: true)
            state = await AgentState(directory: directory, secrets: secrets, now: { HelperResponderTests.fixedNow })
            var plan = Plan.newHotPlan(
                name: "Home",
                repository: .s3(S3Location(
                    provider: .b2, endpoint: URL(string: "https://s3.us-west-004.backblazeb2.com")!,
                    bucket: "bucket", prefix: "mac")),
                origin: .created, hostLabel: "mac", sources: ["/Users/me/Documents"], exclusions: [],
                now: HelperResponderTests.fixedNow)
            plan.id = planID
            _ = try await state.savePlan(SavePlanRequest(plan: plan, secrets: []))
            let values = entries ?? [
                .repositoryPassword(planID): "pa ss\"wörd\n",
                .s3AccessKeyID(planID): "key-id",
                .s3SecretAccessKey(planID): "se\"cret\\/",
            ]
            for (key, value) in values { try secrets.inner.write(value, for: key) }
        }

        deinit { try? FileManager.default.removeItem(at: directory) }

        var responder: HelperResponder {
            HelperResponder(
                state: state, secrets: secrets, supervised: supervised,
                parentOf: { $0 == HelperResponderTests.caller ? HelperResponderTests.restic : nil },
                now: { HelperResponderTests.fixedNow })
        }

        func superviseRestic(for plan: UUID? = nil) async {
            await supervised.insert(pid: HelperResponderTests.restic, planID: plan ?? planID)
        }

        func request(_ kind: HelperRequest.Kind, planID: String? = nil) throws -> Data {
            try XPCCoding.encode(HelperRequest(kind: kind, planID: planID ?? self.planID.uuidString))
        }
    }

    private static func refusal(_ result: Result<Data, HelperResponder.Refusal>) -> HelperResponder.Refusal? {
        if case .failure(let refusal) = result { refusal } else { nil }
    }

    // MARK: Served

    @Test func passwordIsTheStoredBytesWithNothingAdded() async throws {
        let f = try await Fixture()
        await f.superviseRestic()
        let result = await f.responder.respond(to: try f.request(.repositoryPassword), callerPID: Self.caller)
        #expect(try result.get() == Data("pa ss\"wörd\n".utf8))
    }

    @Test func s3CredentialsAreTheCredentialProcessJSON() async throws {
        let f = try await Fixture()
        await f.superviseRestic()
        let result = await f.responder.respond(to: try f.request(.s3Credentials), callerPID: Self.caller)
        let expected = try makeCredentialProcessJSON(accessKeyID: "key-id", secret: "se\"cret\\/", now: Self.fixedNow)
        #expect(try result.get() == expected)
    }

    // MARK: Refused

    @Test func unsupervisedCallerIsRefusedWithoutReadingTheKeychain() async throws {
        let f = try await Fixture()
        let result = await f.responder.respond(to: try f.request(.repositoryPassword), callerPID: Self.caller)
        #expect(Self.refusal(result) == .notSupervised)
        #expect(f.secrets.reads.withLock { $0 } == 0)
        #expect(await f.state.takeHelperFailure(planID: f.planID) == nil)
    }

    @Test func resticForAnotherPlanIsRefused() async throws {
        let f = try await Fixture()
        await f.superviseRestic(for: UUID())
        let result = await f.responder.respond(to: try f.request(.s3Credentials), callerPID: Self.caller)
        #expect(Self.refusal(result) == .notSupervised)
        #expect(f.secrets.reads.withLock { $0 } == 0)
    }

    @Test func malformedRequestIsRefused() async throws {
        let f = try await Fixture()
        await f.superviseRestic()
        let result = await f.responder.respond(to: Data("{\"kind\":\"other\"}".utf8), callerPID: Self.caller)
        #expect(Self.refusal(result) == .malformedRequest)
        #expect(f.secrets.reads.withLock { $0 } == 0)
    }

    @Test(arguments: ["", "not-a-uuid", "../plan"])
    func planIDThatIsNotAUUIDIsRefused(_ planID: String) async throws {
        let f = try await Fixture()
        await f.superviseRestic()
        let result = await f.responder.respond(
            to: try f.request(.repositoryPassword, planID: planID), callerPID: Self.caller)
        #expect(Self.refusal(result) == .invalidPlanID)
        #expect(f.secrets.reads.withLock { $0 } == 0)
    }

    @Test func supervisedButUnconfiguredPlanIsRefused() async throws {
        let f = try await Fixture()
        let other = UUID()
        try f.secrets.inner.write("other", for: .repositoryPassword(other))
        await f.superviseRestic(for: other)
        let result = await f.responder.respond(
            to: try f.request(.repositoryPassword, planID: other.uuidString), callerPID: Self.caller)
        #expect(Self.refusal(result) == .unknownPlan)
        #expect(f.secrets.reads.withLock { $0 } == 0)
    }

    // MARK: Keychain failures

    @Test func missingPasswordIsAnErrorAndRecordedForThePlan() async throws {
        let f = try await Fixture(secrets: [:])
        await f.superviseRestic()
        let result = await f.responder.respond(to: try f.request(.repositoryPassword), callerPID: Self.caller)
        guard case .secretUnavailable(let reason)? = Self.refusal(result) else {
            Issue.record("expected secretUnavailable, got \(result)")
            return
        }
        #expect(reason.contains("repository-password"))
        #expect(await f.state.takeHelperFailure(planID: f.planID) == reason)
    }

    @Test func missingS3SecretKeyIsAnErrorAndRecordedForThePlan() async throws {
        let f = try await Fixture(secrets: [.s3AccessKeyID(UUID()): "unrelated"])
        await f.superviseRestic()
        try f.secrets.inner.write("key-id", for: .s3AccessKeyID(f.planID))
        let result = await f.responder.respond(to: try f.request(.s3Credentials), callerPID: Self.caller)
        guard case .secretUnavailable(let reason)? = Self.refusal(result) else {
            Issue.record("expected secretUnavailable, got \(result)")
            return
        }
        #expect(reason.contains("s3-secret-access-key"))
        #expect(!reason.contains("key-id\""))
        #expect(await f.state.takeHelperFailure(planID: f.planID) == reason)
    }

    @Test func keychainErrorIsAnErrorAndRecordedForThePlan() async throws {
        let f = try await Fixture()
        await f.superviseRestic()
        f.secrets.failReads.withLock { $0 = true }
        let result = await f.responder.respond(to: try f.request(.repositoryPassword), callerPID: Self.caller)
        guard case .secretUnavailable(let reason)? = Self.refusal(result) else {
            Issue.record("expected secretUnavailable, got \(result)")
            return
        }
        #expect(reason.contains("-25308"))
        #expect(await f.state.takeHelperFailure(planID: f.planID) == reason)
        #expect(await f.state.takeHelperFailure(planID: f.planID) == nil)
    }

    // MARK: credential_process JSON

    @Test func credentialProcessJSONAlwaysCarriesVersionKeysAndExpirationIn12Hours() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)  // 2027-01-15T08:00:00Z
        let data = try makeCredentialProcessJSON(accessKeyID: "AKID", secret: "pa\"ss\\word", now: now)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["Version"] as? Int == 1)
        #expect(object["AccessKeyId"] as? String == "AKID")
        #expect(object["SecretAccessKey"] as? String == "pa\"ss\\word")
        #expect(object["Expiration"] as? String == "2027-01-15T20:00:00Z")
        #expect(Set(object.keys) == ["Version", "AccessKeyId", "SecretAccessKey", "Expiration"])
        let expiration = try Date.ISO8601FormatStyle().parse(try #require(object["Expiration"] as? String))
        #expect(expiration == now.addingTimeInterval(12 * 3600))
    }
}
