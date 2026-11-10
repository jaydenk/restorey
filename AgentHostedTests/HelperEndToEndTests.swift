import Foundation
import Testing
import RestoreyCore

/// The confused-deputy negative control (spec §7; docs/spike-findings.md H2): the installed,
/// correctly signed helper, run by hand rather than by a restic the agent is supervising, gets nothing.
///
/// It needs the dev build installed (`scripts/install-dev.sh`) and its agent registered and running
/// (`RestoreyDev --register`; restart it after an install with
/// `launchctl kickstart -k gui/$(id -u)/com.jaydenkerr.restorey.dev.agent`). Without that it fails,
/// rather than skips. The test host is not the launchd agent, so it can't supervise a restic; the
/// positive end-to-end check through the real helper is a manual check (plan Task 17).
@Suite struct HelperEndToEndTests {
    static let installedHelper = URL(fileURLWithPath:
        "/Applications/RestoreyDev.app/Contents/Helpers/RestoreyDevAgent.app/Contents/MacOS/RestoreyDevAgent")

    struct Run {
        let pid: pid_t
        let status: Int32
        let stdout: Data
        let stderr: Data
    }

    /// Runs the helper from this test process and returns once it exits. An agent build without helper
    /// mode would start its run loop and never exit, so give up after 45 s (above the helper's 30 s).
    static func runHelper(_ arguments: [String]) throws -> Run {
        let process = Process()
        process.executableURL = installedHelper
        process.arguments = arguments
        // A plain environment, as restic gives it. The test host's own (DYLD_* paths into DerivedData)
        // would load the test build's frameworks into the installed binary.
        process.environment = ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin"]
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let deadline = Date().addingTimeInterval(45)
        while process.isRunning && Date() < deadline { usleep(50_000) }
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
            Issue.record("the installed helper didn't exit within 45 s: is the installed build older than Task 13?")
        }
        return Run(
            pid: process.processIdentifier, status: process.terminationStatus,
            stdout: out.fileHandleForReading.readDataToEndOfFile(),
            stderr: err.fileHandleForReading.readDataToEndOfFile())
    }

    @Test func helperRunByHandIsRefused() throws {
        try #require(
            FileManager.default.isExecutableFile(atPath: Self.installedHelper.path),
            "RestoreyDev isn't installed: run scripts/install-dev.sh, then RestoreyDev --register")
        let identity = try Identity.fromBundle(.main)
        let agentLog = identity.logsDirectory().appendingPathComponent("agent.log")

        for command in ["print-password", "s3-credentials"] {
            let run = try Self.runHelper([command, "--plan", UUID().uuidString])
            #expect(run.status == 1, "\(command) exited \(run.status)")
            #expect(run.stdout.isEmpty, "\(command) wrote \(run.stdout.count) bytes to stdout")
            #expect(run.stderr.isEmpty, "helper failures go to os_log, not stderr: \(String(decoding: run.stderr, as: UTF8.self))")

            // Exit 1 is also what a missing agent gives, so check the agent itself refused this pid
            // for the launch-chain reason, not for some earlier failure.
            let expected = "Refused a helper request from pid \(run.pid): the caller wasn't started by a restic run"
            var found = false
            for _ in 0..<40 where !found {
                let text = (try? String(contentsOf: agentLog, encoding: .utf8)) ?? ""
                found = text.contains(expected)
                if !found { usleep(50_000) }
            }
            #expect(found, """
                \(agentLog.path) has no refusal for pid \(run.pid). Is the registered agent running the \
                installed Task 13 build? Restart it with launchctl kickstart -k.
                """)
        }
    }

    @Test func helperWithMalformedArgumentsGivesNothing() throws {
        try #require(
            FileManager.default.isExecutableFile(atPath: Self.installedHelper.path),
            "RestoreyDev isn't installed: run scripts/install-dev.sh, then RestoreyDev --register")
        let run = try Self.runHelper(["print-password", "--account", "x"])
        #expect(run.status == 1)
        #expect(run.stdout.isEmpty)
        #expect(run.stderr.isEmpty)
    }
}
