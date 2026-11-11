import Foundation
import Testing
@testable import RestoreyCore

/// `resticRunsUnderAgent` against real processes: a stand-in "agent" in a fake `Contents/Helpers/` runs
/// a stand-in `restic` from the same folder, as the real agent does.
@Suite(.timeLimit(.minutes(1)))
struct AgentResticProbeTests {
    /// A tiny program built once per bundle: `spawn <path> <args…>` starts that child and waits for it (the
    /// agent's part); a number sleeps that long (restic's). Copies of Apple's own tools won't run from
    /// another path (launch constraints), so the stand-ins are built here.
    private static let source = """
        #include <spawn.h>
        #include <stdlib.h>
        #include <string.h>
        #include <sys/wait.h>
        #include <unistd.h>
        extern char **environ;
        int main(int argc, char **argv) {
            if (argc > 2 && strcmp(argv[1], "spawn") == 0) {
                pid_t pid;
                if (posix_spawn(&pid, argv[2], NULL, NULL, argv + 2, environ) != 0) return 1;
                int status;
                waitpid(pid, &status, 0);
                return 0;
            }
            // Sleeps, but goes as soon as its parent has (a test that ends early leaves nothing behind).
            for (int i = argc > 1 ? atoi(argv[1]) : 30; i > 0 && getppid() != 1; i--) sleep(1);
            return 0;
        }
        """

    private struct Bundle {
        let root: URL
        let helpers: URL
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("restorey-probe-\(UUID().uuidString)")
            helpers = root.appendingPathComponent("Restorey.app/Contents/Helpers", isDirectory: true)
            try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
            let source = root.appendingPathComponent("standin.c")
            try AgentResticProbeTests.source.write(to: source, atomically: true, encoding: .utf8)
            let built = root.appendingPathComponent("standin")
            let cc = Process()
            cc.executableURL = URL(fileURLWithPath: "/usr/bin/cc")
            cc.arguments = ["-o", built.path, source.path]
            try cc.run()
            cc.waitUntilExit()
            guard cc.terminationStatus == 0 else { throw CocoaError(.executableLoad) }
            try FileManager.default.copyItem(at: built, to: helpers.appendingPathComponent("Agent"))
            try FileManager.default.copyItem(at: built, to: helpers.appendingPathComponent("restic"))
        }
        var prefix: String { helpers.path + "/" }
        var agent: URL { helpers.appendingPathComponent("Agent") }
        var restic: URL { helpers.appendingPathComponent("restic") }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    /// Runs `executable` with `arguments` until the returned process is terminated.
    private func start(_ executable: URL, _ arguments: [String]) throws -> Process {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        try process.run()
        return process
    }

    private func eventually(_ condition: () -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    @Test func findsAResticRunningUnderTheAgent() async throws {
        let bundle = try Bundle()
        defer { bundle.remove() }
        #expect(!resticRunsUnderAgent(helpersPrefix: bundle.prefix))
        let agent = try start(bundle.agent, ["spawn", bundle.restic.path, "30"])
        defer { agent.terminate() }
        #expect(try await eventually { resticRunsUnderAgent(helpersPrefix: bundle.prefix) })
        // Without the trailing slash too.
        #expect(resticRunsUnderAgent(helpersPrefix: String(bundle.prefix.dropLast())))
    }

    @Test func ignoresAResticWhoseParentIsNotTheAgent() async throws {
        let bundle = try Bundle()
        defer { bundle.remove() }
        // Started by this test process, which lives outside the bundle.
        let restic = try start(bundle.restic, ["30"])
        defer { restic.terminate() }
        try await Task.sleep(for: .milliseconds(200))
        #expect(!resticRunsUnderAgent(helpersPrefix: bundle.prefix))
    }

    @Test func ignoresAnotherBundlesRestic() async throws {
        let ours = try Bundle()
        let theirs = try Bundle()
        defer { ours.remove(); theirs.remove() }
        let agent = try start(theirs.agent, ["spawn", theirs.restic.path, "30"])
        defer { agent.terminate() }
        #expect(try await eventually { resticRunsUnderAgent(helpersPrefix: theirs.prefix) })
        #expect(!resticRunsUnderAgent(helpersPrefix: ours.prefix))
    }
}
