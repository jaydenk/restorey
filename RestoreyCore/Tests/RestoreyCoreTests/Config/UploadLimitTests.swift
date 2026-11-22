import Foundation
import Testing
@testable import RestoreyCore

struct UploadLimitTests {
    private func json(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    @Test func macUploadLimitRoundTripsEachKind() throws {
        for limit in [MacUploadLimit.none, .rate(kiB: 2048, unit: .megabytes), .rate(kiB: 500, unit: .kilobytes), .percent(50)] {
            let data = try JSONEncoder().encode(limit)
            #expect(try JSONDecoder().decode(MacUploadLimit.self, from: data) == limit)
        }
        let rate = try json(MacUploadLimit.rate(kiB: 2048, unit: .megabytes))
        #expect(rate.contains("\"kind\":\"rate\""))
        #expect(rate.contains("\"unit\":\"MB\""))
        #expect(rate.contains("\"kiB\":2048"))
        #expect(try json(MacUploadLimit.none) == "{\"kind\":\"none\"}")
        #expect(try json(MacUploadLimit.percent(50)) == "{\"kind\":\"percent\",\"percent\":50}")
    }

    @Test func anUnknownKindIsRefused() {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(MacUploadLimit.self, from: Data("{\"kind\":\"fast\"}".utf8))
        }
    }

    @Test func theWindowRoundTripsAndIsOmittedWhenNil() throws {
        let window = LimitWindow(days: .weekdays, startMinute: 480, endMinute: 1080)
        let settings = NetworkSettings(
            uploadLimit: .percent(50), limitWindow: window, skipOnConstrainedNetwork: true, skippedWiFiNames: [])
        #expect(try JSONDecoder().decode(NetworkSettings.self, from: JSONEncoder().encode(settings)) == settings)
        #expect(try json(window) == "{\"days\":\"weekdays\",\"endMinute\":1080,\"startMinute\":480}")
    }

    @Test func windowIsOmittedWhenNil() throws {
        let encoded = try json(NetworkSettings.defaults)
        #expect(!encoded.contains("limitWindow"))
        #expect(encoded.contains("\"uploadLimit\":{\"kind\":\"none\"}"))
    }

    @Test func settingsWithoutAnUploadLimitDecodeAsNone() throws {
        let old = Data("{\"skipOnConstrainedNetwork\":true,\"skippedWiFiNames\":[],\"uploadLimitKiB\":500}".utf8)
        let decoded = try JSONDecoder().decode(NetworkSettings.self, from: old)
        #expect(decoded.uploadLimit == .none)
        #expect(decoded.limitWindow == nil)
    }

    private func settings(_ limit: MacUploadLimit, window: LimitWindow? = nil, names: [String] = []) -> NetworkSettings {
        NetworkSettings(uploadLimit: limit, limitWindow: window, skipOnConstrainedNetwork: true, skippedWiFiNames: names)
    }

    @Test func validationRefusesEachBadLimitAndWindow() {
        #expect(settings(.rate(kiB: 0, unit: .megabytes)).validationErrors() == [.limitNotPositive])
        #expect(settings(.rate(kiB: -1, unit: .kilobytes)).validationErrors() == [.limitNotPositive])
        #expect(settings(.percent(0)).validationErrors() == [.percentOutOfRange(0)])
        #expect(settings(.percent(101)).validationErrors() == [.percentOutOfRange(101)])
        #expect(settings(.none, window: LimitWindow(days: .everyDay, startMinute: 480, endMinute: 480)).validationErrors()
            == [.windowStartEqualsEnd])
        #expect(settings(.none, window: LimitWindow(days: .everyDay, startMinute: 0, endMinute: 1440)).validationErrors()
            == [.windowTimeInvalid])
        #expect(settings(.none, window: LimitWindow(days: .everyDay, startMinute: -1, endMinute: 60)).validationErrors()
            == [.windowTimeInvalid])
    }

    @Test func validLimitsAndWindowsPassClean() {
        #expect(settings(.percent(1)).validationErrors().isEmpty)
        #expect(settings(.percent(100)).validationErrors().isEmpty)
        #expect(settings(.rate(kiB: 1, unit: .kilobytes)).validationErrors().isEmpty)
        // Crossing midnight.
        #expect(settings(.none, window: LimitWindow(days: .weekends, startMinute: 1320, endMinute: 360)).validationErrors().isEmpty)
    }

    @Test func errorsComeInOrderLimitWindowThenWiFi() {
        let all = settings(.percent(0), window: LimitWindow(days: .everyDay, startMinute: 5, endMinute: 5), names: [" "])
        #expect(all.validationErrors() == [.percentOutOfRange(0), .windowStartEqualsEnd, .emptyWiFiName])
    }

    @Test func theNewErrorsHaveTheirSentences() {
        #expect(NetworkSettingsError.percentOutOfRange(0).message == "The upload limit must be a percentage from 1 to 100")
        #expect(NetworkSettingsError.windowStartEqualsEnd.message == "The limit’s start and end times can’t be the same")
        #expect(NetworkSettingsError.windowTimeInvalid.message == "A limit time must be within the day")
        #expect(NetworkSettingsError.limitNotPositive.message == "The upload limit must be more than 0 KiB/s")
    }

    @Test func planWithoutUnitDecodesAsMegabytes() throws {
        let plan = Plan.newHotPlan(
            name: "P", repository: .raw(repository: "/tmp/r", environmentNames: []), origin: .created,
            hostLabel: "h", sources: ["/tmp"], exclusions: [], now: Date(timeIntervalSince1970: 0))
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(plan)) as? [String: Any])
        object.removeValue(forKey: "uploadLimitUnit")
        let decoded = try JSONDecoder().decode(Plan.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.uploadLimitUnit == .megabytes)

        var kilobytes = plan
        kilobytes.uploadLimitUnit = .kilobytes
        #expect(try JSONDecoder().decode(Plan.self, from: JSONEncoder().encode(kilobytes)).uploadLimitUnit == .kilobytes)
    }
}
