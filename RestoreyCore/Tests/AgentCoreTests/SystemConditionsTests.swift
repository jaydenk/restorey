import Foundation
import Testing
@testable import AgentCore
import RestoreyCore

/// The readings behind the pre-run checks: mount points on the real file system, and the power state
/// from IOKit's power source descriptions.
struct SystemConditionsTests {
    // MARK: Mount points

    /// The boot volume's alias in /Volumes, a symlink to `/` (named "Macintosh HD" unless renamed).
    private static func bootAlias() throws -> String {
        let names = try FileManager.default.contentsOfDirectory(atPath: "/Volumes")
        let alias = names.first { name in
            (try? FileManager.default.destinationOfSymbolicLink(atPath: "/Volumes/\(name)")) == "/"
        }
        return try #require(alias.map { "/Volumes/\($0)" }, "no /Volumes entry links to /")
    }

    @Test func theRootIsAMountPoint() {
        #expect(SystemConditions.isMountPoint("/"))
    }

    @Test func theBootVolumeAliasIsAMountPoint() throws {
        #expect(SystemConditions.isMountPoint(try Self.bootAlias()))
    }

    @Test func aPlainFolderIsNot() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("restorey-mount-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(!SystemConditions.isMountPoint(folder.path))
        #expect(!SystemConditions.isMountPoint(NSHomeDirectory()))

        // Nor is a symlink to one.
        let link = folder.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: NSHomeDirectory())
        #expect(!SystemConditions.isMountPoint(link.path))
    }

    @Test func aMissingPathIsNot() {
        #expect(!SystemConditions.isMountPoint("/Volumes/restorey-no-such-volume-\(UUID().uuidString)"))
        #expect(!SystemConditions.isMountPoint(""))
    }

    // MARK: Power

    private static func battery(current: Int, max: Int, present: Bool = true) -> [String: Any] {
        ["Type": "InternalBattery", "Current Capacity": current, "Max Capacity": max, "Is Present": present]
    }

    @Test func aDesktopIsNeverOnBattery() {
        #expect(SystemConditions.powerState(providingType: "AC Power", sources: []) == PowerState(onBattery: false, percent: nil))
        #expect(SystemConditions.powerState(providingType: nil, sources: []) == PowerState(onBattery: false, percent: nil))
    }

    @Test func aLaptopOnBatteryReportsItsCharge() {
        #expect(
            SystemConditions.powerState(providingType: "Battery Power", sources: [Self.battery(current: 37, max: 100)])
                == PowerState(onBattery: true, percent: 37))
        // Capacity is current over max, not a raw mAh figure.
        #expect(
            SystemConditions.powerState(providingType: "Battery Power", sources: [Self.battery(current: 2500, max: 5000)])
                == PowerState(onBattery: true, percent: 50))
    }

    @Test func aLaptopOnACIsNotOnBattery() {
        #expect(
            SystemConditions.powerState(providingType: "AC Power", sources: [Self.battery(current: 80, max: 100)])
                == PowerState(onBattery: false, percent: 80))
    }

    @Test func anUnreadableChargeIsNil() {
        #expect(
            SystemConditions.powerState(providingType: "Battery Power", sources: [Self.battery(current: 50, max: 0)])
                == PowerState(onBattery: true, percent: nil))
        #expect(
            SystemConditions.powerState(providingType: "Battery Power", sources: [["Type": "InternalBattery"]])
                == PowerState(onBattery: true, percent: nil))
        // A UPS or a removed battery isn't the Mac's charge.
        #expect(
            SystemConditions.powerState(
                providingType: "Battery Power",
                sources: [["Type": "UPS", "Current Capacity": 10, "Max Capacity": 100], Self.battery(current: 9, max: 10, present: false)])
                == PowerState(onBattery: true, percent: nil))
    }

    @Test func theRealPowerSourcesCanBeRead() {
        // Whatever this Mac is, reading it doesn't crash and a charge is a percentage.
        let state = SystemConditions.currentPowerState()
        if let percent = state.percent { #expect((0...100).contains(percent)) }
    }
}
