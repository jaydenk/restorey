import Foundation
import Testing
@testable import RestoreyCore

struct NetworkSettingsTests {
    private func settings(limit: Int? = nil, names: [String] = []) -> NetworkSettings {
        NetworkSettings(uploadLimitKiB: limit, skipOnConstrainedNetwork: true, skippedWiFiNames: names)
    }

    // MARK: Validation (Review Focus 5)

    @Test func theDefaultsAreValid() {
        #expect(NetworkSettings.defaults.validationErrors().isEmpty)
        #expect(settings(limit: 1, names: ["Home", "Café"]).validationErrors().isEmpty)
    }

    @Test(arguments: [0, -5])
    func aLimitThatIsntPositiveIsRefused(limit: Int) {
        #expect(settings(limit: limit).validationErrors() == [.limitNotPositive])
    }

    @Test func aNameOfSpacesAloneIsRefused() {
        #expect(settings(names: ["  "]).validationErrors() == [.emptyWiFiName])
        #expect(settings(names: ["", "Home", " \t"]).validationErrors() == [.emptyWiFiName], "reported once")
    }

    /// Names match case-insensitively, so two that differ only in case are the same network.
    @Test func aDuplicateNameIsRefused() {
        #expect(settings(names: ["Home", "home"]).validationErrors() == [.duplicateWiFiName("home")])
        #expect(settings(names: ["Home", " Home "]).validationErrors() == [.duplicateWiFiName("Home")],
                "compared trimmed")
        #expect(settings(names: ["Home", "home", "HOME"]).validationErrors() == [.duplicateWiFiName("home")],
                "reported once per network")
    }

    @Test func everyProblemIsListed() {
        #expect(settings(limit: 0, names: [" ", "a", "A"]).validationErrors()
            == [.limitNotPositive, .emptyWiFiName, .duplicateWiFiName("A")])
    }

    @Test func eachProblemReadsAsASentence() {
        #expect(NetworkSettingsError.limitNotPositive.message == "The upload limit must be more than 0 KiB/s")
        #expect(NetworkSettingsError.emptyWiFiName.message == "A Wi-Fi network name can't be empty")
        #expect(NetworkSettingsError.duplicateWiFiName("home").message
            == "The Wi-Fi network “home” is in the list more than once")
    }

    @Test func savingTrimsTheNames() {
        #expect(settings(names: ["  Home ", "Café\n"]).normalised().skippedWiFiNames == ["Home", "Café"])
    }

    // MARK: Matching

    @Test func theCurrentNetworkMatchesIgnoringCase() {
        #expect(settings(names: ["café"]).isSkipped(wiFiName: "Café"))
        #expect(settings(names: [" Home "]).isSkipped(wiFiName: "Home"))
        #expect(!settings(names: ["Home"]).isSkipped(wiFiName: "Home 5G"))
        #expect(!settings(names: ["Cafe"]).isSkipped(wiFiName: "Café"), "accents are part of the name")
    }

    /// "é" as one code point and as "e" plus a combining accent are the same name.
    @Test func canonicallyEquivalentNamesMatch() {
        #expect(settings(names: ["Cafe\u{301}"]).isSkipped(wiFiName: "Caf\u{E9}"))
    }

    // MARK: Upload limits (Ruling P2-7)

    @Test func effectiveUploadLimit() {
        #expect(effectiveUploadLimitKiB(plan: nil, macWide: nil, networkedBackupsRunning: 1) == nil)
        #expect(effectiveUploadLimitKiB(plan: 500, macWide: nil, networkedBackupsRunning: 1) == 500)
        #expect(effectiveUploadLimitKiB(plan: nil, macWide: 1000, networkedBackupsRunning: 2) == 500)
        #expect(effectiveUploadLimitKiB(plan: 300, macWide: 1000, networkedBackupsRunning: 2) == 300)
        #expect(effectiveUploadLimitKiB(plan: nil, macWide: 1000, networkedBackupsRunning: 3) == 333)
        #expect(effectiveUploadLimitKiB(plan: nil, macWide: 1, networkedBackupsRunning: 4) == 1, "never 0")
        #expect(effectiveUploadLimitKiB(plan: 900, macWide: 1000, networkedBackupsRunning: 1) == 900)
        #expect(effectiveUploadLimitKiB(plan: 900, macWide: 600, networkedBackupsRunning: 1) == 600)
    }

    /// A count below 1 can't happen (the backup starting counts itself), but must never divide by zero.
    @Test func aCountBelowOneIsTreatedAsOne() {
        #expect(effectiveUploadLimitKiB(plan: nil, macWide: 1000, networkedBackupsRunning: 0) == 1000)
    }
}
