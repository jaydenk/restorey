import Foundation

/// A small HFS+ RAM disk, for testing a full disk without filling the real one.
/// Always `detach()` it in a `defer`, so a failing test does not leave a volume mounted.
final class RamDisk: @unchecked Sendable {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    let device: String
    let mountPoint: URL

    init(megabytes: Int) throws {
        let sectors = megabytes * 1024 * 1024 / 512
        let attached = try RamDisk.tool("/usr/bin/hdiutil", ["attach", "-nomount", "ram://\(sectors)"])
        // hdiutil also prints a deprecation warning, so look for the device line.
        guard let device = attached.split(whereSeparator: \.isNewline)
            .map({ $0.trimmingCharacters(in: .whitespaces) })
            .first(where: { $0.hasPrefix("/dev/disk") })
        else { throw Failure(description: "hdiutil attach printed \(attached)") }
        self.device = device
        let name = "RestoreyTest\(UUID().uuidString.prefix(8))"
        do {
            _ = try RamDisk.tool("/usr/sbin/diskutil", ["eraseVolume", "HFS+", name, device])
        } catch {
            _ = try? RamDisk.tool("/usr/bin/hdiutil", ["detach", "-force", device])
            throw error
        }
        mountPoint = URL(fileURLWithPath: "/Volumes/\(name)")
    }

    func detach() {
        _ = try? RamDisk.tool("/usr/bin/hdiutil", ["detach", "-force", device])
    }

    @discardableResult
    private static func tool(_ path: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw Failure(description: "\(path) \(arguments.joined(separator: " ")) exited \(process.terminationStatus): \(text)")
        }
        return text
    }
}
