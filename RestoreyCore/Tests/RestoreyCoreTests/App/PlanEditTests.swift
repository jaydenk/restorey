import Foundation
import Testing
@testable import RestoreyCore

/// Settings → Plans edits a copy of a saved plan (UI design §6.2): what counts as a change, which warnings show,
/// when saving pauses backups for a new kit, and the request a save sends.
struct PlanEditTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private static func plan(_ repository: Repository? = nil, origin: RepositoryOrigin = .created) -> Plan {
        var plan = Plan.newHotPlan(
            name: "MacBook",
            repository: repository ?? .s3(S3Location(
                provider: .b2, endpoint: URL(string: "https://s3.us-west-004.backblazeb2.com")!,
                bucket: "my-backups", prefix: "mac")),
            origin: origin, hostLabel: "mac", sources: ["/Users/me"], exclusions: ["/Users/me/Library/Caches"],
            now: now)
        plan.setupCompletedAt = now
        plan.recoveryKitConfirmedAt = now
        return plan
    }

    private static let raw = Repository.raw(repository: "rest:http://nas:8000/mac", environmentNames: ["RESTIC_REST_PASSWORD"])

    // MARK: Changes

    @Test func aFreshEditIsUnchangedAndSendsThePlanAsSaved() throws {
        let plan = Self.plan()
        let edit = PlanEdit(plan: plan)
        #expect(!edit.isDirty)
        #expect(edit.problem == nil)
        let request = try edit.request().get()
        #expect(request.plan == plan)
        #expect(request.secrets.isEmpty)
    }

    /// Task 16a: the Schedule caption says the next run time will change only for an edit that can change it.
    @Test func onlyTheIntervalMakesTheScheduleDirty() {
        var edit = PlanEdit(plan: Self.plan())
        edit.fields.name = "MacBook Pro"
        edit.fields.schedule.hourly = "12"
        edit.fields.schedule.battery = .neverOnBattery
        #expect(edit.isDirty)
        #expect(!edit.scheduleIsDirty)
        edit.fields.schedule.intervalHours = 6
        #expect(edit.scheduleIsDirty)
        edit.fields.schedule.intervalHours = ScheduleForm(plan: Self.plan()).intervalHours
        #expect(!edit.scheduleIsDirty)
    }

    @Test func editingAFieldMakesItDirtyAndEditingBackDoesNot() {
        var edit = PlanEdit(plan: Self.plan())
        edit.fields.name = "MacBook Pro"
        #expect(edit.isDirty)
        edit.fields.name = "MacBook"
        #expect(!edit.isDirty)
        edit.fields.schedule.intervalHours = 4
        #expect(edit.isDirty)
        edit.revert()
        #expect(!edit.isDirty)
    }

    @Test func aTypedSecretIsAChangeAndAnEmptyOneIsNot() {
        var edit = PlanEdit(plan: Self.plan())
        edit.setSecret("", for: .repositoryPassword(edit.planID))
        #expect(!edit.isDirty)
        edit.setSecret("new key", for: .s3SecretAccessKey(edit.planID))
        #expect(edit.isDirty)
    }

    /// The fields store what is typed, unchanged (Task 9's binding rule): trimming happens in the request.
    @Test func fieldsKeepWhatIsTypedAndTheRequestNormalises() throws {
        var edit = PlanEdit(plan: Self.plan())
        edit.fields.hostLabel = "  studio  "
        edit.fields.name = " Studio Mac "
        #expect(edit.fields.hostLabel == "  studio  ")
        let request = try edit.request().get()
        #expect(request.plan.hostLabel == "studio")
        #expect(request.plan.name == "Studio Mac")
    }

    @Test func theRequestCarriesEveryEditedField() throws {
        var edit = PlanEdit(plan: Self.plan())
        edit.fields.sources = ["/Users/me", "/Volumes/Photos"]
        edit.fields.exclusions = []
        edit.fields.fileTypeExclusions = ["dmg"]
        edit.fields.oneFileSystem = false
        edit.fields.skipsItemsMarkedNotForBackup = false
        edit.fields.backUpAnyway = ["/Users/me/Lightroom"]
        edit.fields.schedule.intervalHours = 6
        edit.fields.schedule.battery = .neverOnBattery
        edit.fields.schedule.daily = "7"
        edit.fields.uploadLimit = "1.5"
        edit.fields.pruneEnabled = false
        edit.fields.forgetCadence = .daily
        edit.fields.noSuccessAlertDays = 5
        let plan = try edit.request().get().plan
        #expect(plan.sources == ["/Users/me", "/Volumes/Photos"])
        #expect(plan.exclusions.isEmpty)
        #expect(plan.fileTypeExclusions == ["dmg"])
        #expect(!plan.oneFileSystem)
        #expect(!plan.skipsItemsMarkedNotForBackup)
        #expect(plan.backUpAnyway == ["/Users/me/Lightroom"])
        #expect(plan.schedule == .interval(seconds: 6 * 3600))
        #expect(plan.conditions.battery == .neverOnBattery)
        #expect(plan.retention.daily == 7)
        #expect(plan.uploadLimitKiB == 1536)
        #expect(!plan.pruneEnabled)
        #expect(plan.forgetCadence == .daily)
        #expect(plan.noSuccessAlertDays == 5)
    }

    /// A value the form can't show exactly (an interval or battery rule set elsewhere, a limit with more decimals
    /// than the field shows) is kept as saved unless that control is changed: saving the name mustn't move it.
    @Test func valuesTheFormRoundsAreKeptUnlessTheirControlChanges() throws {
        var plan = Self.plan()
        plan.schedule = .interval(seconds: 5400)
        plan.conditions.battery = .minimumPercent(35)
        plan.uploadLimitKiB = 1000
        var edit = PlanEdit(plan: plan)
        #expect(edit.fields.uploadLimit == "0.98")
        #expect(!edit.isDirty)
        edit.fields.name = "Renamed"
        let saved = try edit.request().get().plan
        #expect(saved.schedule == .interval(seconds: 5400))
        #expect(saved.conditions.battery == .minimumPercent(35))
        #expect(saved.uploadLimitKiB == 1000)

        edit.fields.uploadLimit = ""
        edit.fields.schedule.intervalHours = 1
        let changed = try edit.request().get().plan
        #expect(changed.uploadLimitKiB == nil)
        #expect(changed.schedule == .interval(seconds: 3600))
    }

    // MARK: Problems

    @Test func eachProblemIsASentenceAndStopsTheRequest() {
        var edit = PlanEdit(plan: Self.plan())
        edit.fields.name = "  "
        #expect(edit.nameProblem == "The plan needs a name.")
        #expect(edit.problem == "The plan needs a name.")
        #expect(throws: FormValidation.Problem.self) { try edit.request().get() }
        edit.revert()

        edit.fields.hostLabel = ""
        #expect(edit.hostLabelProblem == "The host label can’t be empty.")
        edit.revert()

        edit.fields.sources = []
        #expect(edit.sourcesProblem == "Add at least one folder or drive to back up.")
        edit.revert()

        edit.fields.uploadLimit = "0"
        #expect(edit.uploadLimitProblem == "The upload limit must be more than 0 MB/s. Leave it empty for no limit.")
        edit.revert()

        edit.fields.schedule.hourly = "x"
        #expect(edit.retentionProblem == "Enter a whole number from 0 to 9999.")
        edit.revert()

        edit.setSecret("ftp://example.com", for: .checkInURL(edit.planID))
        #expect(edit.checkInProblem == "The check-in URL is a web address starting with https://.")
        for problem in [edit.problem] { #expect(problem?.hasSuffix(".") == true) }
    }

    /// A rotated S3 or B2 key comes as a pair: one half alone would leave restic with a mismatched key.
    @Test func aNewStorageKeyNeedsBothHalves() throws {
        var edit = PlanEdit(plan: Self.plan())
        edit.setSecret("new-id", for: .s3AccessKeyID(edit.planID))
        #expect(edit.keyPairProblem == "Enter both the key ID and the application key: a new key comes as a pair.")
        edit.setSecret("new-secret", for: .s3SecretAccessKey(edit.planID))
        #expect(edit.keyPairProblem == nil)
        let secrets = try edit.request().get().secrets
        #expect(Set(secrets.map(\.key)) == [.s3AccessKeyID(edit.planID), .s3SecretAccessKey(edit.planID)])

        var s3 = PlanEdit(plan: Self.plan(.s3(S3Location(
            provider: .s3, endpoint: URL(string: "https://s3.amazonaws.com")!, bucket: "b", prefix: ""))))
        s3.setSecret("only-secret", for: .s3SecretAccessKey(s3.planID))
        #expect(s3.keyPairProblem == "Enter both the access key ID and the secret access key: a new key comes as a pair.")
    }

    // MARK: Secrets

    @Test func theStorageTabsSecretsFollowTheRepository() {
        let s3 = PlanEdit(plan: Self.plan())
        #expect(s3.credentialKeys == [.repositoryPassword(s3.planID), .s3AccessKeyID(s3.planID), .s3SecretAccessKey(s3.planID)])
        let raw = PlanEdit(plan: Self.plan(Self.raw))
        #expect(raw.credentialKeys == [.repositoryPassword(raw.planID), .environment(raw.planID, name: "RESTIC_REST_PASSWORD")])
    }

    @Test func onlyTypedSecretsAreSentAsTyped() throws {
        var edit = PlanEdit(plan: Self.plan(Self.raw))
        let key = SecretKey.environment(edit.planID, name: "RESTIC_REST_PASSWORD")
        edit.setSecret(" pa ss\"wörd\n", for: key)
        let secrets = try edit.request().get().secrets
        #expect(secrets == [SecretEntry(key: key, value: " pa ss\"wörd\n")])
    }

    /// The pause warning: a password or storage key typed (UI design §6.2, "pause until you save the kit"). The
    /// check-in URL isn't part of what opens the repository, so it doesn't pause anything.
    @Test func savingANewKeyOrPasswordPausesBackupsAndTheCheckInURLDoesNot() {
        #expect(PlanEdit.pauseWarning == "Saving pauses backups until you save a new recovery kit.")
        var edit = PlanEdit(plan: Self.plan())
        #expect(!edit.pausesBackups)
        edit.setSecret("https://hc-ping.com/abc", for: .checkInURL(edit.planID))
        edit.fields.name = "Renamed"
        #expect(!edit.pausesBackups)
        edit.setSecret("new password", for: .repositoryPassword(edit.planID))
        #expect(edit.pausesBackups)
        edit.setSecret("", for: .repositoryPassword(edit.planID))
        #expect(!edit.pausesBackups)
        var raw = PlanEdit(plan: Self.plan(Self.raw))
        raw.setSecret("v", for: .environment(raw.planID, name: "RESTIC_REST_PASSWORD"))
        #expect(raw.pausesBackups)
    }

    /// Ruling R2: a changed repository password is tried on the repository before anything is saved.
    @Test func aTypedPasswordIsCheckedFirstAndOnlyAnOpenedRepositoryLetsTheSaveGoOn() {
        var edit = PlanEdit(plan: Self.plan())
        #expect(edit.credentialsToCheck == nil)
        edit.setSecret("new-key", for: .s3AccessKeyID(edit.planID))
        edit.setSecret("https://hc-ping.com/x", for: .checkInURL(edit.planID))
        #expect(edit.credentialsToCheck == nil)
        edit.setSecret(" new pass\n", for: .repositoryPassword(edit.planID))
        // Every typed credential goes with the password, as typed, so keys and password saved together are checked
        // together; the check-in URL isn't a credential.
        #expect(edit.credentialsToCheck == [
            SecretEntry(key: .repositoryPassword(edit.planID), value: " new pass\n"),
            SecretEntry(key: .s3AccessKeyID(edit.planID), value: "new-key"),
        ])

        let report = AdoptReport(hosts: ["mac"], latestPathsForHost: [], snapshotCount: 3)
        #expect(PlanEdit.passwordProblem(after: .existing(report)) == nil)
        #expect(PlanEdit.passwordProblem(after: .passwordRejected)
            == "The repository doesn’t open with this password. Nothing was saved.")
        #expect(PlanEdit.passwordProblem(after: .empty)
            == "There’s no repository at this plan’s address, so the password can’t be checked. Nothing was saved.")
    }

    @Test func secretsNeverAppearInDescriptions() {
        var edit = PlanEdit(plan: Self.plan())
        edit.setSecret("hunter2-secret", for: .repositoryPassword(edit.planID))
        for text in [edit.description, edit.debugDescription, String(reflecting: edit), "\(Mirror(reflecting: edit).children.map(\.value))"] {
            #expect(!text.contains("hunter2-secret"))
        }
        #expect(edit.description.contains("repository-password"))
    }

    // MARK: Check-in URL

    @Test func theCheckInURLIsAddedReplacedOrRemoved() throws {
        var plan = Self.plan()
        var edit = PlanEdit(plan: plan)
        edit.setSecret(" https://hc-ping.com/abc ", for: .checkInURL(plan.id))
        var request = try edit.request().get()
        #expect(request.plan.hasCheckInURL)
        #expect(request.secrets == [SecretEntry(key: .checkInURL(plan.id), value: "https://hc-ping.com/abc")])

        plan.hasCheckInURL = true
        edit = PlanEdit(plan: plan)
        #expect(try edit.request().get().plan.hasCheckInURL)
        edit.fields.removeCheckInURL = true
        #expect(edit.isDirty)
        request = try edit.request().get()
        #expect(!request.plan.hasCheckInURL)
        #expect(request.secrets.isEmpty)
        // "Remove", then a new one typed, replaces it.
        edit.setSecret("https://hc-ping.com/new", for: .checkInURL(plan.id))
        request = try edit.request().get()
        #expect(request.plan.hasCheckInURL)
        #expect(request.secrets == [SecretEntry(key: .checkInURL(plan.id), value: "https://hc-ping.com/new")])
    }

    // MARK: Warnings (product spec §5.4, §5.6)

    @Test func changingTheHostLabelWarnsOfANewSnapshotGroup() {
        var edit = PlanEdit(plan: Self.plan())
        #expect(edit.hostLabelWarning == nil)
        edit.fields.hostLabel = " mac "
        #expect(edit.hostLabelWarning == nil)
        edit.fields.hostLabel = "studio"
        #expect(edit.hostLabelWarning == "Backups under “studio” start a new snapshot group: the next backup reads every file again "
            + "(it doesn’t upload them again), and this plan’s retention no longer thins the snapshots under “mac”, which are kept as they are. "
            + "Saving pauses backups until you save a new recovery kit, since its restore commands name the host label.")
    }

    @Test func changingTheFoldersWarnsOfANewSnapshotGroup() {
        var edit = PlanEdit(plan: Self.plan())
        edit.fields.sources = ["/Users/me/"]
        #expect(edit.sourcesWarning == nil)
        edit.fields.exclusions = []
        #expect(edit.sourcesWarning == nil)
        edit.fields.sources = ["/Users/me", "/Volumes/Photos"]
        #expect(edit.sourcesWarning == "A different list of folders starts a new snapshot group: the next backup reads every file "
            + "again (it doesn’t upload them again), and this plan’s retention no longer thins the snapshots of the previous "
            + "folders, which are kept as they are.")
    }

    // MARK: The agent's plan changing underneath

    @Test func anUneditedFormFollowsTheSavedPlan() {
        var edit = PlanEdit(plan: Self.plan())
        var latest = Self.plan()
        latest.id = edit.planID
        latest.fileTypeExclusions = ["iso"]
        latest.recoveryKitConfirmedAt = nil
        edit.rebase(on: latest)
        #expect(edit.fields.fileTypeExclusions == ["iso"])
        #expect(edit.saved == latest)
        #expect(!edit.isDirty)
    }

    @Test func editsInProgressSurviveTheSavedPlanChanging() throws {
        let plan = Self.plan()
        var edit = PlanEdit(plan: plan)
        edit.fields.name = "Mine"
        edit.setSecret("typed", for: .repositoryPassword(plan.id))
        var latest = plan
        latest.recoveryKitConfirmedAt = nil
        latest.offMacNoteDismissed = true
        edit.rebase(on: latest)
        #expect(edit.fields.name == "Mine")
        #expect(edit.secret(.repositoryPassword(plan.id)) == "typed")
        #expect(try edit.request().get().plan.offMacNoteDismissed)
    }

    /// Fix round 1, minor 4: after a rebase, a save sends only what the user changed; a field they never touched
    /// keeps the agent's newer value rather than the one the form started with.
    @Test func aSaveAfterARebaseSendsOnlyWhatWasChanged() throws {
        let plan = Self.plan()
        var edit = PlanEdit(plan: plan)
        edit.fields.name = "Mine"
        var latest = plan
        latest.fileTypeExclusions = ["iso"]
        latest.retention.daily = 9
        latest.uploadLimitKiB = 2048
        latest.schedule = .interval(seconds: 7200)
        latest.sources = ["/Users/me", "/Volumes/Photos"]
        edit.rebase(on: latest)
        let sent = try edit.request().get().plan
        #expect(sent.name == "Mine")
        #expect(sent.fileTypeExclusions == ["iso"])
        #expect(sent.retention.daily == 9)
        #expect(sent.uploadLimitKiB == 2048)
        #expect(sent.schedule == .interval(seconds: 7200))
        #expect(sent.sources == ["/Users/me", "/Volumes/Photos"])
        // Nothing the user didn't touch is warned about either.
        #expect(edit.sourcesWarning == nil)
        #expect(edit.hostLabelWarning == nil)
    }

    /// Ruling R3: the kit's restore commands name the host label, so a new one pauses backups for a new kit too.
    @Test func aNewHostLabelPausesBackupsAndSaysSo() {
        var edit = PlanEdit(plan: Self.plan())
        edit.fields.hostLabel = " mac "
        #expect(!edit.pausesBackups)
        edit.fields.hostLabel = "studio"
        #expect(edit.pausesBackups)
        #expect(edit.hostLabelWarning?.hasSuffix(
            "Saving pauses backups until you save a new recovery kit, since its restore commands name the host label.") == true)
    }

    @Test func savingResetsTheFormAndDropsTheSecrets() {
        let plan = Self.plan()
        var edit = PlanEdit(plan: plan)
        edit.fields.name = "Mine"
        edit.setSecret("typed", for: .repositoryPassword(plan.id))
        edit.fields.removeCheckInURL = true
        var saved = plan
        saved.name = "Mine"
        edit.didSave(saved)
        #expect(edit.saved == saved)
        #expect(edit.fields == PlanEdit.Fields(plan: saved))
        #expect(edit.secret(.repositoryPassword(plan.id)) == "")
        #expect(!edit.isDirty)
    }

    @Test func closingDropsTheSecretsAndKeepsTheFields() {
        var edit = PlanEdit(plan: Self.plan())
        edit.fields.name = "Mine"
        edit.setSecret("typed", for: .repositoryPassword(edit.planID))
        edit.close()
        #expect(edit.secret(.repositoryPassword(edit.planID)) == "")
        #expect(edit.fields.name == "Mine")
    }
}
