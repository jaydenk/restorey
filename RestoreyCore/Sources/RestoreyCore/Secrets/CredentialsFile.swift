import Foundation

/// The AWS-style shared credentials file that carries B2/S3 keys to restic without an environment
/// variable (docs/spike-findings.md, H4): restic's S3 backend asks the `credential_process`
/// helper for keys on every command.
public enum CredentialsFile {
    public enum Error: Swift.Error, Equatable {
        /// minio-go splits `credential_process` on `strings.Fields`, which splits on any Unicode whitespace.
        case pathContainsWhitespace(String)
        /// `#` and `;` can start a comment in an INI parser, which would truncate the command.
        case pathContainsCommentCharacter(String)
        case unexpectedMode(path: String, mode: Int)
        case posix(operation: String, code: Int32)
    }

    /// Writes `<directory>/s3/<planID>.ini` (0600, in a 0700 folder) and returns its URL.
    /// The file is written to a temporary name in the same folder and renamed into place, so a
    /// reader never sees a half-written file.
    @discardableResult
    public static func write(planID: UUID, helper: URL, directory: URL) throws -> URL {
        let helperPath = helper.path
        if helperPath.unicodeScalars.contains(where: { $0.properties.isWhitespace }) {
            throw Error.pathContainsWhitespace(helperPath)
        }
        if helperPath.contains(where: { $0 == "#" || $0 == ";" }) {
            throw Error.pathContainsCommentCharacter(helperPath)
        }
        let id = planID.uuidString
        let contents = "[restorey-\(id)]\ncredential_process = \(helperPath) s3-credentials --plan \(id)\n"

        let folder = directory.appendingPathComponent("s3", isDirectory: true)
        try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // createDirectory does not touch the mode of a folder that already exists.
        try posix("chmod", chmod(folder.path, 0o700))
        try requireMode(folder, 0o700)

        let destination = folder.appendingPathComponent("\(id).ini")
        let temporary = folder.appendingPathComponent(".\(id).\(UUID().uuidString).tmp")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        try posix("open", fd)
        // The descriptor is closed exactly once, before the rename; the catch only unlinks.
        do {
            defer { _ = close(fd) }
            // The umask can only remove bits from 0600, so set it explicitly as well.
            try posix("fchmod", fchmod(fd, 0o600))
            var remaining = Array(contents.utf8)[...]
            while !remaining.isEmpty {
                let written = remaining.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
                try posix("write", Int32(truncatingIfNeeded: written))
                remaining = remaining.dropFirst(written)
            }
            try posix("fsync", fsync(fd))
        } catch {
            unlink(temporary.path)
            throw error
        }
        do {
            try posix("rename", rename(temporary.path, destination.path))
        } catch {
            unlink(temporary.path)
            throw error
        }
        try requireMode(folder, 0o700)
        try requireMode(destination, 0o600)
        return destination
    }

    private static func posix(_ operation: String, _ result: Int32) throws {
        if result < 0 { throw Error.posix(operation: operation, code: errno) }
    }

    private static func requireMode(_ url: URL, _ expected: Int) throws {
        var info = stat()
        try posix("stat", stat(url.path, &info))
        let mode = Int(info.st_mode) & 0o777
        if mode != expected { throw Error.unexpectedMode(path: url.path, mode: mode) }
    }
}
