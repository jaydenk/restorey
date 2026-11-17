import Darwin
import Foundation

/// Writes a file readable only by this user from its first byte (the recovery kit's PDF, UI design §7), and
/// replaces the target in one step. `FileManager.createFile(atPath:contents:attributes:)` doesn't do this: it
/// writes a sibling temporary file with the umask's mode (0644) and narrows the mode afterwards, so the kit was
/// briefly readable by anyone and a crash mid-write left a readable copy behind.
///
/// Here the temporary file is made by `mkstemp(3)` in the target's folder (so `rename(2)` stays on one volume),
/// which creates it with `O_CREAT | O_EXCL` and mode 0600; the data is written and `fsync`ed, then renamed over
/// the target. Any failure unlinks the temporary file and leaves an existing target as it was. On a volume that
/// keeps no permissions (FAT, exFAT) the mode means nothing, as for any file.
public enum PrivateFile {
    public struct Failure: Error, CustomStringConvertible {
        public let description: String
    }

    /// - Parameter beforeRename: called with the finished temporary file just before it replaces the target, for
    ///   tests to look at it (or fail the write); throwing aborts the write.
    public static func write(_ data: Data, to url: URL, beforeRename: (URL) throws -> Void = { _ in }) throws {
        let folder = url.deletingLastPathComponent()
        var template = Array(folder.appendingPathComponent(".\(url.lastPathComponent).XXXXXX").path.utf8CString)
        let descriptor = template.withUnsafeMutableBufferPointer { mkstemp($0.baseAddress!) }
        guard descriptor >= 0 else { throw failure(url, errno) }
        let path = String(decoding: template.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        let temporary = URL(fileURLWithPath: path)
        var open = true
        do {
            defer { if open { Darwin.close(descriptor) } }
            // mkstemp already makes it 0600; say so explicitly rather than rely on it.
            guard fchmod(descriptor, 0o600) == 0 else { throw failure(url, errno) }
            try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
                var offset = 0
                while offset < buffer.count {
                    let written = Darwin.write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
                    if written < 0 {
                        if errno == EINTR { continue }
                        throw failure(url, errno)
                    }
                    // write(2) returning 0 for a non-empty request makes no progress: looping would never end. It is
                    // an I/O failure, not a retry.
                    if written == 0 { throw failure(url, EIO) }
                    offset += written
                }
            }
            guard fsync(descriptor) == 0 else { throw failure(url, errno) }
            open = false
            guard Darwin.close(descriptor) == 0 else { throw failure(url, errno) }
            try beforeRename(temporary)
            guard rename(temporary.path, url.path) == 0 else { throw failure(url, errno) }
        } catch {
            unlink(temporary.path)
            throw error
        }
    }

    private static func strerrorBytes(_ code: Int32) -> [UInt8] {
        guard let text = strerror(code) else { return Array("error \(code)".utf8) }
        return Array(UnsafeBufferPointer(start: text, count: strlen(text))).map { UInt8(bitPattern: $0) }
    }

    private static func failure(_ url: URL, _ code: Int32) -> Failure {
        Failure(description: "Restorey couldn't save the recovery kit to \(url.path): \(String(decoding: strerrorBytes(code), as: UTF8.self))")
    }
}
