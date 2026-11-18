import Foundation
import Testing

@testable import RestoreyCore

/// The recovery kit's contents (UI design §7, product spec §7): the repository address and password, the backend
/// credential names and values, the host label and the restic commands to restore without Restorey.
@Suite struct RecoveryKitDocumentTests {
    static let created = Date(timeIntervalSince1970: 1_794_000_000)

    static func s3Kit(checkIn: Bool) -> RecoveryKitSecrets {
        var plan = RestoreCommandsTests.s3Plan()
        plan.hasCheckInURL = checkIn
        var secrets = RestoreCommandsTests.secrets(plan, password: "correct horse battery", keyID: "0045f00dkeyid",
                                                   secretKey: "K005supersecretkey")
        if checkIn { secrets.append(SecretEntry(key: .checkInURL(plan.id), value: "https://hc-ping.com/abc-123")) }
        return RecoveryKitSecrets(plan: plan, secrets: secrets)
    }

    static func field(_ document: RecoveryKitDocument, _ section: String, _ label: String) -> RecoveryKitDocument.Field? {
        document.sections.first { $0.title == section }?.fields.first { $0.label == label }
    }

    @Test func anS3KitHasTheRepositoryKeysThisMacTheCommandsAndTheCheckInURL() {
        let kit = Self.s3Kit(checkIn: true)
        let document = RecoveryKitDocument.make(kit, createdAt: Self.created)
        #expect(document.sections.map(\.title) == [
            "Repository", "Storage keys", "This Mac", "Restore without Restorey", "Check-in URL",
        ])
        #expect(Self.field(document, "Repository", "Address") == RecoveryKitDocument.Field(
            label: "Address", value: "s3:https://s3.us-west-004.backblazeb2.com/my-bucket/macs/pepper", isSecret: false))
        #expect(Self.field(document, "Repository", "Password") == RecoveryKitDocument.Field(
            label: "Password", value: "correct horse battery", isSecret: true))
        #expect(Self.field(document, "Storage keys", "Key ID") == RecoveryKitDocument.Field(
            label: "Key ID", value: "0045f00dkeyid", isSecret: true))
        #expect(Self.field(document, "Storage keys", "Secret key") == RecoveryKitDocument.Field(
            label: "Secret key", value: "K005supersecretkey", isSecret: true))
        #expect(Self.field(document, "This Mac", "Host label") == RecoveryKitDocument.Field(
            label: "Host label", value: "pepper", isSecret: false))
        #expect(Self.field(document, "Check-in URL", "Check-in URL") == RecoveryKitDocument.Field(
            label: "Check-in URL", value: "https://hc-ping.com/abc-123", isSecret: true))
        #expect(document.planName == "Home")
        #expect(document.createdAt == Self.created)
    }

    @Test func theRestoreSectionIsTheRestoreCommands() {
        let kit = Self.s3Kit(checkIn: false)
        let document = RecoveryKitDocument.make(kit, createdAt: Self.created)
        let commands = RestoreCommands.make(plan: kit.plan, secrets: kit.secrets)
        let fields = document.sections.first { $0.title == "Restore without Restorey" }!.fields
        #expect(fields.map(\.label) == commands.map(\.title))
        #expect(fields.map(\.value) == commands.map(\.revealedText))
        #expect(fields.map(\.concealed) == commands.map(\.text))
        // Only the first command carries secrets.
        #expect(fields.map(\.isSecret) == [true, false, false])
    }

    @Test func theEnvironmentCommandIsSecretEvenWhenItsValuesAreMissing() {
        let plan = RestoreCommandsTests.s3Plan()
        let document = RecoveryKitDocument.make(RecoveryKitSecrets(plan: plan, secrets: []), createdAt: Self.created)
        let fields = document.sections.first { $0.title == "Restore without Restorey" }!.fields
        #expect(fields.map(\.isSecret) == [true, false, false])
    }

    @Test func noCheckInURLNoSection() {
        let document = RecoveryKitDocument.make(Self.s3Kit(checkIn: false), createdAt: Self.created)
        #expect(!document.sections.map(\.title).contains("Check-in URL"))
    }

    @Test func aRawKitListsEachEnvironmentNameAndValue() {
        let plan = Plan.newHotPlan(
            name: "NAS", repository: .raw(repository: "rest:https://nas.local:8000/mac",
                                          environmentNames: ["RESTIC_REST_USERNAME", "RESTIC_REST_PASSWORD"]),
            origin: .adopted, hostLabel: "pepper", sources: ["/Users/me"], exclusions: [], now: Date())
        let kit = RecoveryKitSecrets(plan: plan, secrets: [
            SecretEntry(key: .repositoryPassword(plan.id), value: "pw"),
            SecretEntry(key: .environment(plan.id, name: "RESTIC_REST_USERNAME"), value: "me"),
            SecretEntry(key: .environment(plan.id, name: "RESTIC_REST_PASSWORD"), value: "rest-secret"),
        ])
        let document = RecoveryKitDocument.make(kit, createdAt: Self.created)
        #expect(document.sections.map(\.title) == ["Repository", "Environment variables", "This Mac", "Restore without Restorey"])
        #expect(document.sections[1].fields == [
            RecoveryKitDocument.Field(label: "RESTIC_REST_USERNAME", value: "me", isSecret: true),
            RecoveryKitDocument.Field(label: "RESTIC_REST_PASSWORD", value: "rest-secret", isSecret: true),
        ])
    }

    @Test func aLocalFolderNeedsNoKeys() {
        let plan = Plan.newHotPlan(
            name: "Drive", repository: .raw(repository: "/Volumes/Backup/restic", environmentNames: []),
            origin: .created, hostLabel: "pepper", sources: ["/Users/me"], exclusions: [], now: Date())
        let kit = RecoveryKitSecrets(plan: plan, secrets: [SecretEntry(key: .repositoryPassword(plan.id), value: "pw")])
        let document = RecoveryKitDocument.make(kit, createdAt: Self.created)
        #expect(document.sections.map(\.title) == ["Repository", "This Mac", "Restore without Restorey"])
    }

    @Test func thePasswordIsTheOneResticUses() {
        // restic trims its password command's output, so a stored trailing newline was never part of the
        // repository's password, and a kit that kept it would fail at restic's prompt.
        let plan = RestoreCommandsTests.s3Plan()
        let kit = RecoveryKitSecrets(plan: plan, secrets: RestoreCommandsTests.secrets(plan))
        let document = RecoveryKitDocument.make(kit, createdAt: Self.created)
        #expect(Self.field(document, "Repository", "Password")?.value == "pa ss\"wörd'")
        // Backend keys reach restic as they are stored, so they stay byte for byte.
        #expect(Self.field(document, "Storage keys", "Secret key")?.value == RestoreCommandsTests.awkward)
    }

    @Test func aSecretFieldIsConcealedAsDotsAndAPlainOneIsShown() {
        let document = RecoveryKitDocument.make(Self.s3Kit(checkIn: true), createdAt: Self.created)
        let password = Self.field(document, "Repository", "Password")!
        #expect(password.concealed == "••••••••")
        let address = Self.field(document, "Repository", "Address")!
        #expect(address.concealed == address.value)
        let everything = document.sections.flatMap(\.fields).map(\.concealed).joined(separator: "\n")
        for secret in Self.s3Kit(checkIn: true).secrets { #expect(!everything.contains(secret.value)) }
    }

    @Test func itsDescriptionNamesNoSecret() {
        let kit = Self.s3Kit(checkIn: true)
        let document = RecoveryKitDocument.make(kit, createdAt: Self.created)
        let dumped = [String(describing: document), String(reflecting: document), "\(document.sections)"]
            .joined(separator: "\n")
        var mirrored = ""
        dump(document, to: &mirrored)
        for secret in kit.secrets {
            #expect(!dumped.contains(secret.value), "\(secret.key.account)")
            #expect(!mirrored.contains(secret.value), "\(secret.key.account)")
        }
    }

    // MARK: Where the PDF goes

    @Test func onlyAnInternalFixedDiskIsTheMacsOwn() {
        #expect(RecoveryKitLocation.isOnInternalDisk(isInternal: true, isRemovable: false))
        #expect(!RecoveryKitLocation.isOnInternalDisk(isInternal: false, isRemovable: false))
        #expect(!RecoveryKitLocation.isOnInternalDisk(isInternal: true, isRemovable: true))
        #expect(!RecoveryKitLocation.isOnInternalDisk(isInternal: false, isRemovable: true))
        // Unknown says so rather than staying quiet: the warning is the safe mistake.
        #expect(RecoveryKitLocation.isOnInternalDisk(isInternal: nil, isRemovable: nil))
        #expect(RecoveryKitLocation.isOnInternalDisk(isInternal: nil, isRemovable: false))
        #expect(!RecoveryKitLocation.isOnInternalDisk(isInternal: false, isRemovable: nil))
    }
}
