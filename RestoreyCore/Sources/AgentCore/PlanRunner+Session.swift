import Foundation
import RestoreyCore

/// What a run needs from the plan and the keychain before restic can start.
extension PlanRunner {
    /// What a step needs that comes from the plan and the keychain.
    struct RunSession: Sendable {
        let plan: Plan
        let context: ResticContext
        let redactor: Redactor
        /// `RepositoryQueues.key(for:)` of the plan's repository.
        let key: String
    }

    enum Preparation: Sendable {
        case ready(RunSession)
        /// Restic can't be run. `redactor` holds whatever secrets could be read, for the ping.
        case failed(RunOutcome, reason: String, redactor: Redactor)
    }

    /// A redactor for everything secret the plan has that can be read now: the password, S3 keys, raw
    /// environment values and the check-in URL. Values that can't be read are simply left out.
    func redactor(for plan: Plan) -> Redactor {
        redactorAndEnvironment(for: plan).redactor
    }

    /// Reads the plan's secrets for the redactor (and a raw plan's environment), and writes an S3 plan's
    /// credentials file with the agent as the helper. Only the raw environment is required here: the
    /// password and S3 keys are fetched by restic through the helper, which reports its own failures.
    func prepare(_ plan: Plan) -> Preparation {
        let (redactor, environment, problems) = redactorAndEnvironment(for: plan)
        if !problems.isEmpty {
            let reason = ([Self.keychainUnreadable] + problems).joined(separator: ". ")
            return .failed(.credentialsUnavailable, reason: reason, redactor: redactor)
        }

        var credentialsFile: URL?
        if case .s3 = plan.repository {
            do {
                credentialsFile = try CredentialsFile.write(
                    planID: plan.id, helper: deps.helperExecutable, directory: deps.credentialsDirectory)
            } catch {
                let reason = "Restorey couldn't write the S3 credentials file: \(error)"
                return .failed(.failed(exitCode: Self.startFailureExitCode, reason: reason), reason: reason, redactor: redactor)
            }
        }
        let context = ResticContext(
            cacheDirectory: deps.cacheDirectory, helperExecutable: deps.helperExecutable,
            credentialsFile: credentialsFile, rawEnvironment: environment, homeDirectory: deps.homeDirectory)
        return .ready(RunSession(
            plan: plan, context: context, redactor: redactor, key: RepositoryQueues.key(for: plan.repository)))
    }

    private func redactorAndEnvironment(
        for plan: Plan
    ) -> (redactor: Redactor, environment: [String: String], problems: [String]) {
        var known: [String] = []
        for key in [SecretKey.repositoryPassword(plan.id), .s3AccessKeyID(plan.id), .s3SecretAccessKey(plan.id)] {
            if let value = try? deps.secrets.read(key) { known.append(value) }
        }
        let checkInURL = (try? deps.secrets.read(.checkInURL(plan.id))) ?? nil

        var environment: [String: String] = [:]
        var problems: [String] = []
        if case .raw(_, let names) = plan.repository {
            for name in names {
                do {
                    if let value = try deps.secrets.read(.environment(plan.id, name: name)) {
                        environment[name] = value
                        known.append(value)
                    } else {
                        problems.append("The environment value \(name) isn't in the Keychain")
                    }
                } catch {
                    problems.append("Restorey couldn't read the environment value \(name): \(error)")
                }
            }
        }
        return (Redactor(secrets: known, checkInURLs: checkInURL.map { [$0] } ?? []), environment, problems)
    }
}
