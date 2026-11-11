import Foundation

/// Runs a command-line tool (`dd`, `hdiutil`, `cc`) to completion without blocking a thread of Swift's
/// cooperative pool (Ruling R71). That pool has only as many threads as the machine has cores, and Swift
/// Testing runs suites in parallel on it: a helper that sat in `waitUntilExit()` or `readDataToEndOfFile()`
/// held one for seconds, starving the timing-sensitive tests running beside it on a low-core CI runner.
/// The blocking read and wait happen on a dedicated dispatch queue (which GCD gives its own thread), and
/// the caller is resumed through a continuation.
///
/// (A copy lives in each test target's `Support/`; test targets can't depend on one another.)
enum Tool {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    struct Output: Sendable {
        let status: Int32
        let stdout: Data
        let stderr: String
        /// stdout then stderr, for messages.
        var text: String { String(decoding: stdout, as: UTF8.self) + stderr }
    }

    /// Runs `path` with `arguments` and returns its status and output.
    static func run(_ path: String, _ arguments: [String]) async throws -> Output {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue(label: "restorey.tests.tool").async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = arguments
                let out = Pipe(), err = Pipe()
                process.standardOutput = out
                process.standardError = err
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                try? out.fileHandleForWriting.close()
                try? err.fileHandleForWriting.close()
                // Both pipes at once, so neither can fill and stall the tool.
                nonisolated(unsafe) var errorData = Data()
                let group = DispatchGroup()
                DispatchQueue(label: "restorey.tests.tool.stderr").async(group: group) {
                    errorData = err.fileHandleForReading.readDataToEndOfFile()
                }
                let outputData = out.fileHandleForReading.readDataToEndOfFile()
                group.wait()
                process.waitUntilExit()
                continuation.resume(returning: Output(
                    status: process.terminationStatus, stdout: outputData,
                    stderr: String(decoding: errorData, as: UTF8.self)))
            }
        }
    }

    /// `run`, throwing with the output when the tool exits non-zero.
    @discardableResult
    static func succeed(_ path: String, _ arguments: [String]) async throws -> Output {
        let output = try await run(path, arguments)
        guard output.status == 0 else {
            throw Failure(description: "\(path) \(arguments.joined(separator: " ")) exited \(output.status): \(output.text)")
        }
        return output
    }

    /// `count` files of `megabytes` each of random (incompressible) data, `random-<i>.bin` in `directory`.
    static func writeRandomFiles(count: Int, megabytes: Int, in directory: URL) async throws {
        for i in 0..<count {
            let file = directory.appendingPathComponent("random-\(i).bin")
            try await succeed("/bin/dd", ["if=/dev/urandom", "of=\(file.path)", "bs=1048576", "count=\(megabytes)"])
        }
    }
}
