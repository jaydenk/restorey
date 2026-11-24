import Foundation
import Testing
@testable import RestoreyCore

struct NotificationSettingsTests {
    @Test func defaultsAreProblemsOnly() {
        #expect(NotificationSettings.defaults == NotificationSettings(backupStarted: false, backupFinished: false, problems: true))
    }

    @Test func aMissingKeyTakesItsDefault() throws {
        let settings = try JSONDecoder().decode(NotificationSettings.self, from: Data(#"{"backupStarted":true}"#.utf8))
        #expect(settings == NotificationSettings(backupStarted: true, backupFinished: false, problems: true))
        #expect(try JSONDecoder().decode(NotificationSettings.self, from: Data("{}".utf8)) == .defaults)
    }

    @Test func roundTripsThroughJSON() throws {
        let settings = NotificationSettings(backupStarted: true, backupFinished: true, problems: false)
        let data = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(NotificationSettings.self, from: data) == settings)
    }
}
