import Foundation
import Testing

@testable import RestoreyCore

@Suite struct StorageFormTests {
    private static let planID = UUID(uuidString: "6F9A3C1E-2B4D-4E8F-9A1B-0C2D3E4F5A6B")!

    private static func b2() -> StorageForm {
        var form = StorageForm()
        form.endpoint = " s3.us-west-004.backblazeb2.com "
        form.bucket = "my-backups"
        form.prefix = "/macbook/"
        return form
    }

    @Test func b2IsTheDefaultWithNoEndpoint() {
        let form = StorageForm()
        #expect(form.kind == .b2)
        #expect(form.endpoint.isEmpty)
        #expect(form.endpointProblem == "Enter the endpoint.")
        #expect(form.repositoryValue == nil)
    }

    @Test func b2FormReadsIntoAnS3Location() {
        let repository = Self.b2().repositoryValue
        #expect(repository == .s3(S3Location(
            provider: .b2, endpoint: URL(string: "https://s3.us-west-004.backblazeb2.com")!,
            bucket: "my-backups", prefix: "macbook")))
    }

    @Test func choosingS3FillsInAWSsEndpointOnlyWhenEmpty() {
        var form = StorageForm()
        form.choose(.s3)
        #expect(form.endpoint == "s3.amazonaws.com")
        form.choose(.b2)
        #expect(form.endpoint.isEmpty)
        var typed = Self.b2()
        typed.choose(.s3)
        #expect(typed.endpoint == " s3.us-west-004.backblazeb2.com ")
        guard case .s3(let location)? = typed.repositoryValue else { Issue.record("not S3"); return }
        #expect(location.provider == .s3)
    }

    @Test func problemsComeFromFormValidation() {
        var form = Self.b2()
        form.bucket = "My Backups"
        #expect(form.bucketProblem == "Bucket names are lower case, without spaces.")
        form.bucket = "ok-bucket"
        form.endpoint = "http://s3.example.com"
        #expect(form.endpointProblem?.hasPrefix("http:// is only for a store on this Mac") == true)
        #expect(form.repositoryValue == nil)
    }

    @Test func otherLocationsNeedAFullPathOrABackend() {
        var form = StorageForm(kind: .other)
        #expect(form.repositoryProblem?.hasPrefix("Enter the repository location") == true)
        form.repository = "Backups/restic"
        #expect(form.repositoryProblem == "A folder or drive needs its full path, starting with / (or ~ for your home folder).")
        form.repository = "sftp:nas:/restic"
        #expect(form.repositoryProblem == nil)
        #expect(form.repositoryValue == .raw(repository: "sftp:nas:/restic", environmentNames: []))
        form.repository = "~/restorey-test/new"
        #expect(form.repositoryValue == .raw(repository: NSHomeDirectory() + "/restorey-test/new", environmentNames: []))
        form.repository = "local:~/r"
        #expect(form.repositoryValue == .raw(repository: "local:" + NSHomeDirectory() + "/r", environmentNames: []))
    }

    @Test func environmentNamesAreCheckedOneByOne() {
        var form = StorageForm(kind: .other)
        form.repository = "rest:https://nas.local:8000/"
        let good = StorageForm.EnvironmentRow(name: "RESTIC_REST_PASSWORD")
        let empty = StorageForm.EnvironmentRow(name: " ")
        let bad = StorageForm.EnvironmentRow(name: "1BAD-NAME")
        let reserved = StorageForm.EnvironmentRow(name: "RESTIC_PASSWORD")
        form.environment = [good, empty, bad, reserved, StorageForm.EnvironmentRow(name: "RESTIC_REST_PASSWORD")]
        #expect(form.environmentProblem(good) == "RESTIC_REST_PASSWORD is listed twice.")
        #expect(form.environmentProblem(empty) == "Enter the variable’s name, such as RESTIC_REST_PASSWORD.")
        #expect(form.environmentProblem(bad)?.hasPrefix("A variable name is letters") == true)
        #expect(form.environmentProblem(reserved) == "Restorey sets RESTIC_PASSWORD itself: leave it out.")
        #expect(form.repositoryValue == nil)
        form.environment = [good, StorageForm.EnvironmentRow(name: "RESTIC_REST_USERNAME")]
        #expect(form.repositoryValue == .raw(
            repository: "rest:https://nas.local:8000/", environmentNames: ["RESTIC_REST_PASSWORD", "RESTIC_REST_USERNAME"]))
    }

    @Test func aNewPlanNeedsEveryKeyAndASavedOneKeepsEmptyOnes() {
        let form = Self.b2()
        let id = Self.planID
        let typed: [SecretKey: String] = [.s3AccessKeyID(id): "key id"]
        let missing = form.secretEntries(planID: id, typed: { typed[$0] }, saved: false)
        #expect(missing == .failure("Enter the application key."))
        let kept = form.secretEntries(planID: id, typed: { typed[$0] }, saved: true)
        #expect(kept == .success([SecretEntry(key: .s3AccessKeyID(id), value: "key id")]))
        let both: [SecretKey: String] = [.s3AccessKeyID(id): "key id", .s3SecretAccessKey(id): "pa ss\"wörd'\n"]
        // Secrets go byte for byte: nothing is trimmed.
        #expect(form.secretEntries(planID: id, typed: { both[$0] }, saved: false) == .success([
            SecretEntry(key: .s3AccessKeyID(id), value: "key id"),
            SecretEntry(key: .s3SecretAccessKey(id), value: "pa ss\"wörd'\n"),
        ]))
        let none = form.secretEntries(planID: id, typed: { _ in nil }, saved: false)
        #expect(none == .failure("Enter the key ID and application key."))
    }

    @Test func otherLocationsSendEachEnvironmentValue() {
        var form = StorageForm(kind: .other)
        form.repository = "/Volumes/Backup/restic"
        #expect(form.secretEntries(planID: Self.planID, typed: { _ in nil }, saved: false) == .success([]))
        var a = StorageForm.EnvironmentRow(name: "A_TYPO")
        let b = StorageForm.EnvironmentRow(name: "B")
        form.environment = [a, b]
        // Typed by row, so renaming the row afterwards keeps its value.
        let typed: [UUID: String] = [a.id: "1"]
        a.name = " A "
        form.environment[0] = a
        #expect(form.secretEntries(planID: Self.planID, typed: { _ in nil }, environmentValue: { typed[$0] }, saved: false)
            == .failure("Enter the value of B."))
        let both: [UUID: String] = [a.id: "1", b.id: "two words"]
        #expect(form.secretEntries(planID: Self.planID, typed: { _ in nil }, environmentValue: { both[$0] }, saved: false)
            == .success([
                SecretEntry(key: .environment(Self.planID, name: "A"), value: "1"),
                SecretEntry(key: .environment(Self.planID, name: "B"), value: "two words"),
            ]))
    }

    @Test func emptyKeysCanBeKeptOnlyWhileTheAddressIsTheSavedOne() {
        let form = Self.b2()
        let saved = form.repositoryValue
        #expect(form.keepsSavedSecrets(saved: saved))
        #expect(!form.keepsSavedSecrets(saved: nil))
        var moved = form
        moved.bucket = "other-bucket"
        #expect(!moved.keepsSavedSecrets(saved: saved))
    }

    @Test func aSavedRepositoryFillsTheForm() {
        let s3 = Repository.s3(S3Location(
            provider: .s3, endpoint: URL(string: "https://s3.amazonaws.com")!, bucket: "b-1", prefix: "p"))
        let form = StorageForm(repository: s3)
        #expect(form.kind == .s3)
        #expect(form.repositoryValue == s3)
        let raw = Repository.raw(repository: "/Volumes/X", environmentNames: ["A"])
        #expect(StorageForm(repository: raw).repositoryValue == raw)
    }

    @Test func planNamesSayWhereTheBackupsGo() {
        #expect(StorageForm.planName(for: Self.b2().repositoryValue!) == "B2 · my-backups")
        #expect(StorageForm.planName(for: .raw(repository: "/Volumes/Backup/restic", environmentNames: [])) == "Local · restic")
        #expect(StorageForm.planName(for: .raw(repository: "local:/Volumes/Drive", environmentNames: [])) == "Local · Drive")
        #expect(StorageForm.planName(for: .raw(repository: "sftp:nas:/restic", environmentNames: [])) == "restic · sftp")
        // Named by string handling (L157): `URL(fileURLWithPath:)` stats the path, which a drive that stops answering
        // holds up, and keeps `..` as the name.
        #expect(StorageForm.planName(for: .raw(repository: "/Volumes/Backup/restic/x/..", environmentNames: [])) == "Local · restic")
    }

    @Test func aLocalFolderIsTheFolderKind() {
        let form = StorageForm(repository: .raw(repository: "/Volumes/Backup/restic", environmentNames: []))
        #expect(form.kind == .folder)
        #expect(form.folderPath == "/Volumes/Backup/restic")
        #expect(form.repositoryValue == .raw(repository: "/Volumes/Backup/restic", environmentNames: []))
        let prefixed = StorageForm(repository: .raw(repository: "local:/Volumes/Drive", environmentNames: []))
        #expect(prefixed.kind == .folder)
        #expect(prefixed.folderPath == "/Volumes/Drive")
    }

    @Test func aRemoteOrEnvironmentRawLocationStaysOther() {
        #expect(StorageForm(repository: .raw(repository: "sftp:nas:/restic", environmentNames: [])).kind == .other)
        #expect(StorageForm(repository: .raw(repository: "/Volumes/X", environmentNames: ["A"])).kind == .other)
        #expect(StorageForm(repository: .raw(repository: "Backups/relative", environmentNames: [])).kind == .other)
    }

    @Test func aFolderMustBeChosen() {
        var form = StorageForm()
        form.choose(.folder)
        #expect(form.repositoryProblem == "Choose a folder or drive for the backups.")
        #expect(!form.isValid)
        #expect(form.repositoryValue == nil)
        #expect(form.endpointProblem == nil && form.bucketProblem == nil && form.prefixProblem == nil)
        form.folderPath = "/Volumes/Backup/restic"
        #expect(form.isValid)
    }

    @Test func aFolderHasNoSecrets() {
        var form = StorageForm(kind: .folder)
        form.folderPath = "/Volumes/Backup"
        #expect(form.secretKeys(planID: Self.planID).isEmpty)
        #expect(form.secretEntries(planID: Self.planID, typed: { _ in nil }, saved: false) == .success([]))
        #expect(form.keepsSavedSecrets(saved: form.repositoryValue))
        #expect(StorageForm.planName(for: form.repositoryValue!) == "Local · Backup")
    }

    @Test func kindsAreInOrder() {
        #expect(StorageForm.Kind.allCases == [.b2, .s3, .folder, .other])
        #expect(StorageForm.Kind.folder.title == "Folder or Drive")
        #expect(StorageForm.Kind.folder.helpLink == nil)
    }

    @Test func helpLinksAreTheProvidersDocs() {
        #expect(StorageForm.Kind.b2.helpLink?.url.absoluteString
            == "https://www.backblaze.com/docs/cloud-storage-create-and-manage-app-keys")
        #expect(StorageForm.Kind.s3.helpLink?.url.host() == "docs.aws.amazon.com")
        #expect(StorageForm.Kind.other.helpLink == nil)
    }
}
