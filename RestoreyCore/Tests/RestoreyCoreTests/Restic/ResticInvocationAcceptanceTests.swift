import Foundation
import Testing
@testable import RestoreyCore

/// Runs the builder's real output against the vendored restic 0.19.1, so a renamed or invented
/// flag fails here rather than on a user's machine.
struct ResticInvocationAcceptanceTests {
    private struct Result { let status: Int32; let stdout: String; let stderr: String }

    private func run(_ restic: URL, _ inv: ResticInvocation, dir: URL, tag: String) throws -> Result {
        let process = Process()
        process.executableURL = restic
        process.arguments = inv.arguments
        var env = inv.environment
        env["HOME"] = dir.path
        env["PATH"] = "/usr/bin:/bin"
        process.environment = env
        let out = dir.appendingPathComponent("\(tag).out"), err = dir.appendingPathComponent("\(tag).err")
        FileManager.default.createFile(atPath: out.path, contents: nil)
        FileManager.default.createFile(atPath: err.path, contents: nil)
        process.standardOutput = try FileHandle(forWritingTo: out)
        process.standardError = try FileHandle(forWritingTo: err)
        try process.run()
        process.waitUntilExit()
        return Result(
            status: process.terminationStatus,
            stdout: (try? String(contentsOf: out, encoding: .utf8)) ?? "",
            stderr: (try? String(contentsOf: err, encoding: .utf8)) ?? ""
        )
    }

    private struct Snap: Decodable { let hostname: String; let tags: [String]? }

    @Test func everyOperationIsAcceptedByRestic0191() throws {
        let restic = try TestBinaries.requireRestic()
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("restorey-accept-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        // A fake agent helper: restic runs RESTIC_PASSWORD_COMMAND through the shell.
        let helper = dir.appendingPathComponent("fake-helper.sh")
        try "#!/bin/sh\necho test-password-not-a-secret\n".write(to: helper, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)

        let source = dir.appendingPathComponent("source")
        try fm.createDirectory(at: source.appendingPathComponent("node_modules"), withIntermediateDirectories: true)
        try "hello".write(to: source.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "skip".write(to: source.appendingPathComponent("node_modules/x.js"), atomically: true, encoding: .utf8)

        let repo = dir.appendingPathComponent("repo")
        var plan = Plan.newHotPlan(
            name: "T", repository: .raw(repository: repo.path, environmentNames: []), origin: .created,
            hostLabel: "testhost", sources: [source.path], exclusions: ["**/node_modules"], now: Date()
        )
        plan.uploadLimitKiB = 100_000
        plan.packSizeMiB = 16 // raw plans default to nil; set explicitly to exercise --pack-size.
        let context = ResticContext(
            cacheDirectory: dir.appendingPathComponent("cache"), helperExecutable: helper,
            credentialsFile: nil, rawEnvironment: [:], homeDirectory: dir
        )

        // Foreign snapshots forget must never touch, seeded by direct restic calls.
        func direct(_ args: [String], tag: String) throws {
            var inv = makeInvocation(.check, plan: plan, context: context)
            inv.arguments = args
            let r = try run(restic, inv, dir: dir, tag: tag)
            #expect(r.status == 0, "\(tag): \(r.stderr)")
        }
        let sourcePath = source.path
        let otherTag = "restorey:\(UUID().uuidString)"
        func seed() throws {
            // Two snapshots of the plan's own group, so keep-1 has something to remove.
            for i in 0..<2 {
                try "v\(i)".write(to: source.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
                try direct(["backup", "--host=testhost", "--tag=restorey:\(plan.id.uuidString)", sourcePath], tag: "own\(i)")
            }
            // (a) other host, same tag; (b) same host, no tag; (c) same host, different Restorey tag.
            try direct(["backup", "--host=other-mac", "--tag=restorey:\(plan.id.uuidString)", sourcePath], tag: "seed-a")
            try direct(["backup", "--host=testhost", sourcePath], tag: "seed-b")
            try direct(["backup", "--host=testhost", "--tag=\(otherTag)", sourcePath], tag: "seed-c")
        }
        plan.retention = Retention(hourly: 1, daily: 1, weekly: 1, monthly: 1)

        let sequence: [(String, ResticOperation)] = [
            ("init", .initRepository),
            ("cat-config", .catConfig),
            ("backup", .backup),
            ("snapshots", .snapshots(allHosts: false)),
            ("snapshots-all", .snapshots(allHosts: true)),
            ("forget-dry", .forget(dryRun: true)),
            ("forget", .forget(dryRun: false)),
            ("prune", .prune),
            ("check", .check),
            ("unlock", .unlock),
        ]
        for (name, op) in sequence {
            if name == "forget" { try seed() }
            let inv = makeInvocation(op, plan: plan, context: context)
            let r = try run(restic, inv, dir: dir, tag: name)
            #expect(!r.stderr.contains("unknown flag"), "\(name): \(r.stderr)")
            #expect(!r.stderr.contains("unknown shorthand"), "\(name): \(r.stderr)")
            #expect(r.status == 0, "\(name) exited \(r.status): \(r.stderr)")
            if name == "backup" {
                #expect(r.stdout.contains("\"message_type\":\"summary\""), "backup produced no JSON summary")
            }
            if name == "forget" {
                let all = try run(restic, makeInvocation(.snapshots(allHosts: true), plan: plan, context: context),
                                  dir: dir, tag: "after-forget")
                #expect(all.status == 0, "\(all.stderr)")
                // Keep-1 removed the extra snapshots of the plan's own group, but all three
                // foreign snapshots must survive.
                let snaps = try JSONDecoder().decode([Snap].self, from: Data(all.stdout.utf8))
                let own = "restorey:\(plan.id.uuidString)"
                #expect(snaps.contains { $0.hostname == "other-mac" && ($0.tags ?? []).contains(own) }, "(a) lost")
                #expect(snaps.contains { $0.hostname == "testhost" && ($0.tags ?? []).isEmpty }, "(b) lost")
                #expect(snaps.contains { $0.hostname == "testhost" && ($0.tags ?? []) == [otherTag] }, "(c) lost")
                #expect(snaps.filter { $0.hostname == "testhost" && ($0.tags ?? []) == [own] }.count == 1,
                        "own group should be reduced to one snapshot")
            }
            if name == "snapshots" || name == "snapshots-all" {
                #expect(r.stdout.contains("\"hostname\":\"testhost\""), "\(name): \(r.stdout)")
                #expect(r.stdout.contains("restorey:\(plan.id.uuidString)"), "\(name): \(r.stdout)")
            }
        }
    }
}
