import Foundation
import Testing
@testable import RestoreyCore

/// Task 16c: the words per Full Disk Access state and the item the person drags into System Settings.
struct FullDiskAccessGuideTests {
    @Test func stateFollowsTheAgentsProbe() {
        #expect(FullDiskAccessGuide.State(missing: nil) == .checking)
        #expect(FullDiskAccessGuide.State(missing: true) == .missing)
        #expect(FullDiskAccessGuide.State(missing: false) == .granted)
    }

    @Test func wording() {
        #expect(FullDiskAccessGuide.grantedTitle == "Full Disk Access is on")
        #expect(FullDiskAccessGuide.dragCaption == "Drag this into the list, then switch it on.")
        #expect(FullDiskAccessGuide.why
            == "Without it, Restorey can’t back up Mail, Messages, Safari and other protected folders.")
    }

    @Test func theDragItemIsTheAppBundle() {
        let app = URL(fileURLWithPath: "/Applications/Restorey.app", isDirectory: true)
        #expect(FullDiskAccessGuide.dragItemURL(forBundleAt: app)?.path == "/Applications/Restorey.app")
    }

    /// The agent's binary is inside the app; the grant is the app's, never the helper's.
    @Test func aPathInsideTheBundleResolvesToTheApp() {
        let agent = URL(fileURLWithPath: "/Applications/Restorey.app/Contents/Helpers/RestoreyAgent")
        #expect(FullDiskAccessGuide.dragItemURL(forBundleAt: agent)?.path == "/Applications/Restorey.app")
        #expect(FullDiskAccessGuide.dragItemURL(forBundleAt: agent)?.isFileURL == true)
    }

    @Test func notABundleHasNoItem() {
        #expect(FullDiskAccessGuide.dragItemURL(forBundleAt: URL(fileURLWithPath: "/usr/bin/restic")) == nil)
    }
}
