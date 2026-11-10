import Foundation
import Testing
@testable import RestoreyCore

struct InstallLocationTests {
    private func url(_ path: String) -> URL { URL(fileURLWithPath: path, isDirectory: true) }

    @Test func applicationsIsOK() {
        #expect(installVerdict(bundleURL: url("/Applications/Restorey.app"), isTranslocated: false) == .ok)
    }

    @Test func applicationsSubfolderIsOK() {
        #expect(installVerdict(bundleURL: url("/Applications/Utilities/Restorey.app"), isTranslocated: false) == .ok)
    }

    /// The translocation API's answer wins even for an /Applications path: a copy made by script stays
    /// quarantined and is translocated from there (spike phase B).
    @Test func translocatedRefused() {
        #expect(installVerdict(bundleURL: url("/Applications/Restorey.app"), isTranslocated: true) == .translocated)
        let mounted = url("/private/var/folders/ab/cd/T/AppTranslocation/0B4A-11/d/Restorey.app")
        #expect(installVerdict(bundleURL: mounted, isTranslocated: false) == .translocated)
    }

    @Test func downloadsRefused() {
        let downloads = url("/Users/me/Downloads/Restorey.app")
        #expect(installVerdict(bundleURL: downloads, isTranslocated: false) == .notInApplications(downloads))
    }

    @Test func otherLocationsRefused() {
        for path in [
            "/Volumes/Restorey/Restorey.app", "/Users/me/Applications/Restorey.app", "/Applications",
            "/Applications/Restorey", "/Applications/Other.app/Contents/Restorey.app",
            "/Applications/../Users/me/Restorey.app",
        ] {
            let bundle = url(path)
            #expect(installVerdict(bundleURL: bundle, isTranslocated: false) == .notInApplications(bundle), "\(path)")
        }
    }
}
