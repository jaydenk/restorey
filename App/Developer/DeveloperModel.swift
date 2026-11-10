#if DEBUG
import Foundation
import Observation
import RestoreyCore

/// The developer window's form and actions: enough to make and run a plan before plan 2's real UI.
/// Every action goes through the agent; the app never writes config or secrets itself.
@MainActor
@Observable
final class DeveloperModel {
    enum Kind: String, CaseIterable, Identifiable {
        case b2 = "B2"
        case s3 = "S3"
        case local = "Raw/local repository path"
        var id: String { rawValue }
    }

    /// The plan the buttons act on; nil while making a new one.
    var selectedPlanID: UUID?
    var name = "Developer test"
    var kind = Kind.local
    var endpoint = "https://s3.us-west-004.backblazeb2.com"
    var bucket = ""
    var prefix = ""
    var keyID = ""
    var secret = ""
    var repositoryPassword = ""
    var localPath = "/tmp/restorey-dev-repo"
    /// One absolute path per line.
    var sources = ""
    var checkInURL = ""
    var hostLabel = Host.current().localizedName ?? "Mac"
    var adoptExisting = false
    /// The last action's result or error.
    var output = ""
    var working = false

    @ObservationIgnored let supervisor: AgentSupervisor
    @ObservationIgnored private let identity: Identity

    init(supervisor: AgentSupervisor, identity: Identity) {
        self.supervisor = supervisor
        self.identity = identity
    }

    var plans: [Plan] { supervisor.status?.plans.map(\.plan) ?? [] }

    var selectedPlan: Plan? { plans.first { $0.id == selectedPlanID } }

    /// The live status, pretty-printed. Plans hold no secrets, so it is safe to show.
    var statusJSON: String {
        guard let status = supervisor.status else { return "No status yet" }
        return Self.pretty(status)
    }

    /// Fills the form from a saved plan. Secret fields stay empty: empty means "keep the saved value".
    func load(_ id: UUID?) {
        selectedPlanID = id
        guard let plan = selectedPlan else { return }
        name = plan.name
        hostLabel = plan.hostLabel
        sources = plan.sources.joined(separator: "\n")
        adoptExisting = plan.origin == .adopted
        switch plan.repository {
        case .s3(let location):
            kind = location.provider == .b2 ? .b2 : .s3
            endpoint = location.endpoint.absoluteString
            bucket = location.bucket
            prefix = location.prefix
        case .raw(let repository, _):
            kind = .local
            localPath = repository
        }
        clearSecrets()
    }

    /// Drops every secret the form holds: after a save (successful or not) and when the window closes.
    func clearSecrets() {
        keyID = ""
        secret = ""
        repositoryPassword = ""
        checkInURL = ""
    }

    // MARK: Actions

    func save() {
        let request: SavePlanRequest
        do {
            request = try makeRequest()
        } catch {
            clearSecrets()
            output = "\(error) Enter the secrets again."
            return
        }
        // The request holds the only copy from here on; the form keeps none, whatever the outcome.
        clearSecrets()
        run("Save plan") { [connection = supervisor.connection] in
            let result = await connection.savePlan(request)
            if case .success = result { self.selectedPlanID = request.plan.id }
            return Self.describe(result)
        }
    }

    /// What the "Create repository" confirmation names: the saved plan's full restic repository.
    var createAddress: String? { selectedPlan?.repository.resticRepository }

    var createIsS3: Bool {
        if case .s3 = selectedPlan?.repository { return true }
        return false
    }

    func createRepository() { planAction("Create repository") { await $0.createRepository($1) } }
    func confirmRecoveryKit() { planAction("Recovery details saved") { await $0.confirmRecoveryKit($1) } }
    func backUpNow() { planAction("Back Up Now") { await $0.backUpNow($1) } }
    func pause() { planAction("Pause") { await $0.pause($1) } }
    func resume() { planAction("Resume") { await $0.resume($1) } }
    func adopt() { planAction("Adopt") { await $0.adopt($1) } }

    func requestNotifications() {
        run("Request notifications") { [connection = supervisor.connection] in
            Self.describe(await connection.requestNotificationPermission())
        }
    }

    private func planAction<T: Encodable>(
        _ title: String, _ call: @escaping (AgentConnection, UUID) async -> Result<T, AgentCallError>
    ) {
        guard let id = selectedPlanID else {
            output = "\(title): save or choose a plan first."
            return
        }
        run(title) { [connection = supervisor.connection] in Self.describe(await call(connection, id)) }
    }

    private func run(_ title: String, _ body: @escaping () async -> String) {
        working = true
        output = "\(title)…"
        Task {
            let text = await body()
            output = "\(title): \(text)"
            working = false
        }
    }

    // MARK: Building the request

    struct FormError: Error, CustomStringConvertible {
        let description: String
    }

    func makeRequest() throws -> SavePlanRequest {
        let repository = try makeRepository()
        let sourceList = sources.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            .map { NSString(string: $0).expandingTildeInPath }
        var plan: Plan
        if let existing = selectedPlan {
            plan = existing
            plan.name = name
            plan.repository = repository
            plan.hostLabel = hostLabel
            plan.sources = sourceList
        } else {
            guard !repositoryPassword.isEmpty else { throw FormError(description: "A new plan needs a repository password.") }
            if case .s3 = repository, keyID.isEmpty || secret.isEmpty {
                throw FormError(description: "A new S3 or B2 plan needs a key ID and a secret.")
            }
            let home = FileManager.default.homeDirectoryForCurrentUser
            plan = Plan.newHotPlan(
                name: name, repository: repository, origin: adoptExisting ? .adopted : .created,
                hostLabel: hostLabel, sources: sourceList,
                exclusions: DefaultExclusions.paths(home: home, identity: identity), now: Date())
        }
        // An empty field removes the check-in URL: the agent saves `false` and deletes the secret.
        plan.hasCheckInURL = !checkInURL.isEmpty

        var secrets: [SecretEntry] = []
        if !repositoryPassword.isEmpty { secrets.append(SecretEntry(key: .repositoryPassword(plan.id), value: repositoryPassword)) }
        if case .s3 = repository {
            if !keyID.isEmpty { secrets.append(SecretEntry(key: .s3AccessKeyID(plan.id), value: keyID)) }
            if !secret.isEmpty { secrets.append(SecretEntry(key: .s3SecretAccessKey(plan.id), value: secret)) }
        }
        if !checkInURL.isEmpty { secrets.append(SecretEntry(key: .checkInURL(plan.id), value: checkInURL)) }
        return SavePlanRequest(plan: plan, secrets: secrets)
    }

    private func makeRepository() throws -> Repository {
        switch kind {
        case .local:
            let path = NSString(string: localPath.trimmingCharacters(in: .whitespaces)).expandingTildeInPath
            guard path.hasPrefix("/") else { throw FormError(description: "The repository path must be absolute.") }
            return .raw(repository: path, environmentNames: [])
        case .b2, .s3:
            guard let url = URL(string: endpoint.trimmingCharacters(in: .whitespaces)), url.scheme == "https",
                  url.host() != nil
            else { throw FormError(description: "The endpoint must be an https:// address.") }
            guard !bucket.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw FormError(description: "The bucket can't be empty.")
            }
            return .s3(S3Location(
                provider: kind == .b2 ? .b2 : .s3, endpoint: url,
                bucket: bucket.trimmingCharacters(in: .whitespaces),
                prefix: prefix.trimmingCharacters(in: .whitespaces)))
        }
    }

    // MARK: Formatting

    private static func describe<T: Encodable>(_ result: Result<T, AgentCallError>) -> String {
        switch result {
        case .success(let value): "OK\n" + pretty(value)
        case .failure(let error): error.description
        }
    }

    private static func pretty<T: Encodable>(_ value: T) -> String {
        guard let data = try? XPCCoding.encode(value),
              let object = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(
                withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return "(couldn't format the reply)" }
        return String(decoding: pretty, as: UTF8.self)
    }
}
#endif
