import Foundation

/// A saved plan being edited in Settings → Plans (UI design §6.2): the fields as typed, the secrets typed into the
/// Storage and Schedule tabs (the check-in URL), and every decision about them: whether anything changed, which warnings show, whether
/// saving pauses backups for a new recovery kit, and the request a save sends. Pure; the app's `PlanEditModel`
/// does the call.
///
/// The fields hold exactly what the controls show (the text fields' binding rule): trimming and parsing happen in
/// `request()`, never as the user types. A secret field left empty keeps the saved value. Secrets are never in a
/// description or mirror, and go with `didSave`, `revert` and `close`.
public struct PlanEdit: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// What the tabs edit. The repository address isn't here: a different repository is a new plan (UI design
    /// §6.2), so it is shown read-only.
    public struct Fields: Sendable, Equatable {
        public var name: String
        public var sources: [String]
        public var exclusions: [String]
        public var fileTypeExclusions: [String]
        public var oneFileSystem: Bool
        /// The Folders tab's sheet for items apps mark as not for backup (Task 15c).
        public var skipsItemsMarkedNotForBackup: Bool
        public var backUpAnyway: [String]
        /// The interval, the battery rule and retention (as text), shared with setup's schedule step.
        public var schedule: ScheduleForm
        /// MB/s as typed; empty is no limit (the default, UI design §6.2).
        public var uploadLimit: String
        public var hostLabel: String
        public var pruneEnabled: Bool
        public var forgetCadence: ForgetCadence
        public var noSuccessAlertDays: Int
        /// The Schedule tab's Alerts "Remove" for the saved check-in URL.
        public var removeCheckInURL: Bool

        public init(plan: Plan) {
            name = plan.name
            sources = plan.sources
            exclusions = plan.exclusions
            fileTypeExclusions = plan.fileTypeExclusions
            oneFileSystem = plan.oneFileSystem
            skipsItemsMarkedNotForBackup = plan.skipsItemsMarkedNotForBackup
            backUpAnyway = plan.backUpAnyway
            schedule = ScheduleForm(plan: plan)
            uploadLimit = FormValidation.uploadLimitText(kiB: plan.uploadLimitKiB)
            hostLabel = plan.hostLabel
            pruneEnabled = plan.pruneEnabled
            forgetCadence = plan.forgetCadence
            noSuccessAlertDays = plan.noSuccessAlertDays
            removeCheckInURL = false
        }
    }

    /// The plan as the agent last reported it: what a save is built on.
    public private(set) var saved: Plan
    public var fields: Fields
    /// The fields as they were when editing began (or last saved, reverted or followed the agent): a field that
    /// still equals its start is one the user hasn't changed, and a save leaves the agent's value for it alone.
    private var started: Fields
    private var secrets: [SecretKey: String] = [:]

    public init(plan: Plan) {
        saved = plan
        fields = Fields(plan: plan)
        started = fields
    }

    public var planID: UUID { saved.id }

    // MARK: Secrets

    public func secret(_ key: SecretKey) -> String { secrets[key] ?? "" }

    /// Stores what was typed, as it is; empty is nothing typed (the saved value is kept).
    public mutating func setSecret(_ value: String, for key: SecretKey) {
        secrets[key] = value.isEmpty ? nil : value
    }

    /// The secrets that open the repository, as the Storage tab lists them: the repository password, then both S3
    /// keys, or each environment value of another location. A change to any of them needs a new recovery kit.
    public var credentialKeys: [SecretKey] {
        let id = saved.id
        switch saved.repository {
        case .s3: return [.repositoryPassword(id), .s3AccessKeyID(id), .s3SecretAccessKey(id)]
        case .raw(_, let names): return [.repositoryPassword(id)] + names.map { .environment(id, name: $0) }
        }
    }

    private var checkInKey: SecretKey { .checkInURL(saved.id) }

    /// The form kind the S3 keys are labelled for.
    public var storageKind: StorageForm.Kind {
        switch saved.repository {
        case .s3(let location): location.provider == .b2 ? .b2 : .s3
        case .raw: .other
        }
    }

    // MARK: State

    /// Something differs from the saved plan, or a secret has been typed.
    public var isDirty: Bool { fields != started || !secrets.isEmpty }

    /// The interval differs from the saved plan's: the only schedule field that moves the next run time, so the
    /// Schedule tab's caption says it will change on saving only then.
    public var scheduleIsDirty: Bool { fields.schedule.intervalHours != started.schedule.intervalHours }

    /// Shown before saving whenever a password or storage key has been typed: the saved kit holds the old one, so
    /// the agent stops the plan's backups until a new kit is saved and confirmed (UI design §6.2). The check-in
    /// URL isn't needed to open the repository and pauses nothing.
    ///
    /// A new host label does too (Ruling R3): the kit's restore commands pass it as `--host`.
    public var pausesBackups: Bool { credentialKeys.contains { secrets[$0] != nil } || newHostLabel != nil }

    /// The host label the user typed, trimmed, when it differs from the saved one.
    private var newHostLabel: String? {
        guard fields.hostLabel != started.hostLabel else { return nil }
        let label = fields.hostLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        return label.isEmpty || label == saved.hostLabel ? nil : label
    }

    public static let pauseWarning = "Saving pauses backups until you save a new recovery kit."

    // MARK: Warnings (product spec §5.4, §5.6)

    /// A new host label starts a new `host,paths` group.
    public var hostLabelWarning: String? {
        guard let label = newHostLabel else { return nil }
        return "Backups under “\(label)” start a new snapshot group: the next backup reads every file again (it doesn’t "
            + "upload them again), and this plan’s retention no longer thins the snapshots under “\(saved.hostLabel)”, "
            + "which are kept as they are. Saving pauses backups until you save a new recovery kit, since its restore "
            + "commands name the host label."
    }

    /// A different set of folders starts a new group. Compared as written, as restic records them
    /// (`FormValidation.addingSources`): a trailing slash is the same folder, a link to it isn't.
    public var sourcesWarning: String? {
        guard !fields.sources.isEmpty, fields.sources != started.sources else { return nil }
        let before = Set(FormValidation.addingSources(saved.sources, to: []))
        let after = Set(FormValidation.addingSources(fields.sources, to: []))
        guard before != after else { return nil }
        return "A different list of folders starts a new snapshot group: the next backup reads every file again (it "
            + "doesn’t upload them again), and this plan’s retention no longer thins the snapshots of the previous "
            + "folders, which are kept as they are."
    }

    // MARK: Problems (each a sentence ending with a full stop)

    public var nameProblem: String? {
        let name = fields.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return "The plan needs a name." }
        if name.contains(where: \.isNewline) { return "The plan’s name must be on one line." }
        return nil
    }

    public var hostLabelProblem: String? { FormValidation.hostLabel(fields.hostLabel) }

    /// Also a folder inside the plan's own local repository, by path, as the agent's validation judges it: v0.1 allowed
    /// one, so a plan saved then stops until it is taken off the list (final review I2), and this tab says which.
    public var sourcesProblem: String? {
        if fields.sources.isEmpty { return "Add at least one folder or drive to back up." }
        guard let repositoryPath = saved.repository.localFolderPath,
            let inside = fields.sources.first(where: { SourcePaths.containsByPath(repositoryPath, $0) })
        else { return nil }
        return FormValidation.sentence(PlanValidationError.sourceInsideRepository(inside).message)
    }

    public var retentionProblem: String? {
        if case .failure(let problem) = fields.schedule.retention { return problem.message }
        return nil
    }

    public var uploadLimitProblem: String? {
        if case .failure(let problem) = FormValidation.uploadLimit(fields.uploadLimit) { return problem.message }
        return nil
    }

    public var checkInProblem: String? { ScheduleForm.checkInProblem(secret(checkInKey)) }

    /// A rotated S3 or B2 key is a new pair: one half alone would leave restic with a mismatched key.
    public var keyPairProblem: String? {
        guard case .s3 = saved.repository else { return nil }
        let id = SecretKey.s3AccessKeyID(saved.id), key = SecretKey.s3SecretAccessKey(saved.id)
        guard (secrets[id] == nil) != (secrets[key] == nil) else { return nil }
        let kind = storageKind
        return "Enter both the \(StorageForm.label(for: id, kind: kind)) and the \(StorageForm.label(for: key, kind: kind)): "
            + "a new key comes as a pair."
    }

    /// The first problem, in the order of the tabs.
    public var problem: String? {
        [nameProblem, sourcesProblem, uploadLimitProblem, hostLabelProblem, keyPairProblem, retentionProblem, checkInProblem]
            .lazy.compactMap { $0 }.first
    }

    // MARK: Saving

    /// The save request, or the first problem. Built on the saved plan, so fields the tabs don't show (the kit
    /// confirmation, the off-Mac note) go back as the agent sent them; the agent keeps its own copy of those anyway.
    /// Only what the user changed is applied: a field still at its start keeps the saved plan's value, so a value
    /// the form rounds (an interval, battery rule or upload limit it can't show exactly) is kept, and after a rebase
    /// a field the user never touched keeps the agent's newer value.
    public func request() -> Result<SavePlanRequest, FormValidation.Problem> {
        if let problem { return .failure(.init(problem)) }
        var plan = saved
        func changed<Value: Equatable>(_ field: KeyPath<Fields, Value>) -> Bool { fields[keyPath: field] != started[keyPath: field] }
        if changed(\.name) { plan.name = fields.name.trimmingCharacters(in: .whitespacesAndNewlines) }
        if changed(\.sources) { plan.sources = fields.sources }
        if changed(\.exclusions) { plan.exclusions = fields.exclusions }
        if changed(\.fileTypeExclusions) { plan.fileTypeExclusions = fields.fileTypeExclusions }
        if changed(\.oneFileSystem) { plan.oneFileSystem = fields.oneFileSystem }
        if changed(\.skipsItemsMarkedNotForBackup) { plan.skipsItemsMarkedNotForBackup = fields.skipsItemsMarkedNotForBackup }
        if changed(\.backUpAnyway) { plan.backUpAnyway = fields.backUpAnyway }
        if changed(\.schedule.intervalHours) { plan.schedule = .interval(seconds: fields.schedule.intervalHours * 3600) }
        if changed(\.schedule.battery) { plan.conditions.battery = fields.schedule.battery }
        let retentionText = [\Fields.schedule.hourly, \.schedule.daily, \.schedule.weekly, \.schedule.monthly]
        if retentionText.contains(where: changed), case .success(let retention) = fields.schedule.retention {
            plan.retention = retention
        }
        if changed(\.uploadLimit), case .success(let limit) = FormValidation.uploadLimit(fields.uploadLimit) {
            plan.uploadLimitKiB = limit
        }
        if changed(\.hostLabel) { plan.hostLabel = fields.hostLabel.trimmingCharacters(in: .whitespacesAndNewlines) }
        if changed(\.pruneEnabled) { plan.pruneEnabled = fields.pruneEnabled }
        if changed(\.forgetCadence) { plan.forgetCadence = fields.forgetCadence }
        if changed(\.noSuccessAlertDays) { plan.noSuccessAlertDays = fields.noSuccessAlertDays }

        let typedURL = secret(checkInKey)
        let intent: CheckInIntent
        do {
            // "Remove" and then a new URL typed is a replacement, not both at once.
            intent = try checkInIntent(
                existing: saved.hasCheckInURL, field: typedURL, remove: fields.removeCheckInURL && typedURL.isEmpty)
        } catch {
            return .failure(.init(FormValidation.sentence("\(error)")))
        }
        plan.hasCheckInURL = intent.hasCheckInURL
        var entries = credentialKeys.compactMap { key in secrets[key].map { SecretEntry(key: key, value: $0) } }
        if let url = intent.secret { entries.append(SecretEntry(key: checkInKey, value: url)) }
        return .success(SavePlanRequest(plan: plan, secrets: entries))
    }

    /// What Settings tries on the repository before saving (Ruling R2), when a repository password is typed: it and
    /// every other typed credential (storage keys, environment values), as typed, so a password and keys saved
    /// together are checked together. The field can't change the repository's own password, so a mistyped one
    /// would otherwise only show at the next backup. Nil when no password is typed.
    public var credentialsToCheck: [SecretEntry]? {
        guard secrets[.repositoryPassword(saved.id)] != nil else { return nil }
        return credentialKeys.compactMap { key in secrets[key].map { SecretEntry(key: key, value: $0) } }
    }

    /// What the check of `credentialsToCheck` found, as the field's sentence, or nil when the repository opened with it
    /// and the save can go on.
    public static func passwordProblem(after probe: RepositoryProbe.State) -> String? {
        switch probe {
        case .existing: nil
        case .passwordRejected: "The repository doesn’t open with this password. Nothing was saved."
        case .empty: "There’s no repository at this plan’s address, so the password can’t be checked. Nothing was saved."
        }
    }

    /// The agent's copy of the plan changed (a save elsewhere, a kit confirmed, a file type normalised). An
    /// untouched form follows it; edits in progress are kept, and are now compared with it.
    ///
    /// Edits in progress keep their start, so a save still knows which fields the user changed (`request`).
    public mutating func rebase(on latest: Plan) {
        guard latest.id == saved.id, latest != saved else { return }
        let untouched = fields == started
        saved = latest
        if untouched {
            fields = Fields(plan: latest)
            started = fields
        }
    }

    /// The agent saved `plan`: the form starts again from it, and the typed secrets go.
    public mutating func didSave(_ plan: Plan) {
        saved = plan
        fields = Fields(plan: plan)
        started = fields
        secrets = [:]
    }

    /// "Revert": back to the saved plan, secrets dropped.
    public mutating func revert() {
        fields = Fields(plan: saved)
        started = fields
        secrets = [:]
    }

    /// The tab or window is going: the secrets go now.
    public mutating func close() {
        secrets = [:]
    }

    // MARK: Descriptions (never a secret)

    public var description: String {
        let accounts = secrets.keys.map(\.account).sorted().joined(separator: ", ")
        return "PlanEdit(plan: \(saved.id.uuidString) \"\(saved.name)\", dirty: \(isDirty), secrets: [\(accounts)])"
    }
    public var debugDescription: String { description }
    public var customMirror: Mirror {
        Mirror(
            self, children: ["saved": saved, "fields": fields, "secrets": secrets.keys.map(\.account).sorted()],
            displayStyle: .struct)
    }
}
