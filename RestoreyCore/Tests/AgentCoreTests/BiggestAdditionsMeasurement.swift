import Darwin
import Foundation
import Testing
@testable import AgentCore
@testable import RestoreyCore

/// Task 16d's cost measurement, off unless asked for: `RESTOREY_MEASURE_16D=1 RESTOREY_MEASURE_DIR=<empty folder>
/// nice -n 20 swift test --filter BiggestAdditionsMeasurement`. It builds a tree of 100,000 small files of unique data,
/// backs it up to two local repositories, once as before Task 16d (no `--verbose`) and once with `--verbose` and the
/// biggest-additions reader, then changes 1,000 files and backs up both again. restic runs under `/usr/bin/time -l` for
/// its own CPU and peak memory; the reader's CPU is this process's, and its memory this process's footprint. Each
/// message goes through what the runner does with it (`StepLog.lines`, the collector). Prints one line per backup.
/// It deletes everything it wrote under `RESTOREY_MEASURE_DIR` (about 1 GB) when it ends, pass or fail; remove the
/// empty folder yourself.
struct BiggestAdditionsMeasurement {
    private static let environment = ProcessInfo.processInfo.environment
    private static let fileCount = 100_000
    private static let changedCount = 1_000

    private struct Numbers: CustomStringConvertible {
        var label: String
        var wall: Double
        var resticReal = 0.0, resticUser = 0.0, resticSys = 0.0
        var resticMaxRSS: Int64 = 0, resticPeakFootprint: Int64 = 0
        var readerUser = 0.0, readerSys = 0.0
        var footprintBefore: Int64 = 0, footprintAfter: Int64 = 0, maxRSSAfter: Int64 = 0
        var verboseMessages = 0
        var exitCode: Int32 = 0
        var description: String {
            func mb(_ bytes: Int64) -> String { String(format: "%.1f MB", Double(bytes) / 1e6) }
            return "\(label): exit \(exitCode), wall \(String(format: "%.2f", wall)) s; restic real \(resticReal) s, user \(resticUser) s, "
                + "sys \(resticSys) s, max RSS \(mb(resticMaxRSS)), peak footprint \(mb(resticPeakFootprint)); reader (this process) "
                + "user \(String(format: "%.3f", readerUser)) s, sys \(String(format: "%.3f", readerSys)) s, footprint "
                + "\(mb(footprintBefore)) → \(mb(footprintAfter)), max RSS so far \(mb(maxRSSAfter)); verbose messages reaching "
                + "the reader \(verboseMessages)"
        }
    }

    @Test(.enabled(if: environment["RESTOREY_MEASURE_16D"] == "1"), .timeLimit(.minutes(30)))
    func measureTheCostOfVerboseBackups() async throws {
        let restic = try ResticBinary.require()
        let root = URL(fileURLWithPath: try #require(Self.environment["RESTOREY_MEASURE_DIR"]), isDirectory: true)
        let fm = FileManager.default
        #expect(try fm.contentsOfDirectory(atPath: root.path).isEmpty, "RESTOREY_MEASURE_DIR must be empty")
        defer {
            for name in (try? fm.contentsOfDirectory(atPath: root.path)) ?? [] {
                try? fm.removeItem(at: root.appendingPathComponent(name))
            }
            print("MEASURE16D deleted the test data under \(root.path); remove that folder when done")
        }
        let source = root.appendingPathComponent("source")
        try writeTree(at: source)

        let helper = root.appendingPathComponent("helper.sh")
        try "#!/bin/sh\necho measure-password-not-a-secret\n".write(to: helper, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        let context = ResticContext(
            cacheDirectory: root.appendingPathComponent("cache"), helperExecutable: helper, credentialsFile: nil,
            rawEnvironment: [:], homeDirectory: root)
        func plan(_ name: String) -> Plan {
            Plan.newHotPlan(
                name: name, repository: .raw(repository: root.appendingPathComponent(name).path, environmentNames: []),
                origin: .created, hostLabel: "measure", sources: [source.path], exclusions: [], now: Date())
        }
        let before = plan("repo-before"), after = plan("repo-verbose")
        for p in [before, after] {
            let t = try await ResticProcess(
                executable: restic, invocation: makeInvocation(.initRepository, plan: p, context: context), planID: p.id,
                supervisor: SupervisedProcesses(), homeDirectory: root
            ).run { _ in }
            #expect(t.exitCode == 0)
        }

        var results: [Numbers] = []
        results.append(try await backup(before, verbose: false, label: "first, as before", restic: restic, context: context, home: root))
        results.append(try await backup(after, verbose: true, label: "first, --verbose + reader", restic: restic, context: context, home: root))
        try changeFiles(in: source)
        results.append(try await backup(before, verbose: false, label: "second, as before", restic: restic, context: context, home: root))
        results.append(try await backup(after, verbose: true, label: "second, --verbose + reader", restic: restic, context: context, home: root))
        for result in results {
            print("MEASURE16D \(result)")
            #expect(result.exitCode == 0)
        }
    }

    /// 100 folders of 10 folders of 100 files, each 1–4 KB of data no other file has.
    private func writeTree(at source: URL) throws {
        var generator = SystemRandomNumberGenerator()
        let pool = (0..<8_192).map { _ in UInt8.random(in: 0...255, using: &generator) }
        var n = 0
        for a in 0..<100 {
            for b in 0..<10 {
                let folder = source.appendingPathComponent("d\(a)/e\(b)", isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                for c in 0..<100 {
                    try file(n, pool: pool).write(to: folder.appendingPathComponent("f\(c).bin"))
                    n += 1
                }
            }
        }
        #expect(n == Self.fileCount)
    }

    private func file(_ n: Int, pool: [UInt8], salt: UInt64 = 0) -> Data {
        let size = 1_024 + (n * 7_919) % 3_072
        var data = Data(withUnsafeBytes(of: UInt64(n).littleEndian ^ salt) { Array($0) })
        let offset = (n * 104_729) % (pool.count - size)
        data.append(contentsOf: pool[offset..<offset + size - 8])
        return data
    }

    private func changeFiles(in source: URL) throws {
        var generator = SystemRandomNumberGenerator()
        let pool = (0..<8_192).map { _ in UInt8.random(in: 0...255, using: &generator) }
        for i in 0..<Self.changedCount {
            let n = i * (Self.fileCount / Self.changedCount)
            let url = source.appendingPathComponent("d\(n / 1_000)/e\((n / 100) % 10)/f\(n % 100).bin")
            try file(n, pool: pool, salt: 0xA5A5).write(to: url)
        }
    }

    private func backup(
        _ plan: Plan, verbose: Bool, label: String, restic: URL, context: ResticContext, home: URL
    ) async throws -> Numbers {
        var invocation = makeInvocation(.backup, plan: plan, context: context)
        if !verbose { invocation.arguments.removeAll { $0 == "--verbose" } }
        invocation.arguments = ["-l", restic.path] + invocation.arguments
        let collector = verbose ? BiggestAdditionsCollector(sources: plan.sources) : nil
        let timeLines = Locked<[String]>([])
        let verboseCount = Locked(0)

        let usageBefore = Self.selfUsage()
        let footprintBefore = Self.footprint()
        let start = ContinuousClock.now
        let termination = try await ResticProcess(
            executable: URL(fileURLWithPath: "/usr/bin/time"), invocation: invocation, planID: plan.id,
            supervisor: SupervisedProcesses(), homeDirectory: home
        ).run { message in
            // What the runner does with each message, less the log writes and the progress feed's state updates.
            _ = StepLog.lines(for: message, operation: .backup)
            collector?.collect(message)
            switch message {
            case .verboseStatus: verboseCount.mutate { $0 += 1 }
            case .unparseable(let line): timeLines.mutate { $0.append(line) }
            default: break
            }
        }
        let wall = ContinuousClock.now - start
        let usageAfter = Self.selfUsage()

        var numbers = Numbers(label: label, wall: Double(wall.components.seconds) + Double(wall.components.attoseconds) / 1e18)
        numbers.exitCode = termination.exitCode
        numbers.readerUser = usageAfter.user - usageBefore.user
        numbers.readerSys = usageAfter.sys - usageBefore.sys
        numbers.footprintBefore = footprintBefore
        numbers.footprintAfter = Self.footprint()
        numbers.maxRSSAfter = usageAfter.maxRSS
        numbers.verboseMessages = verboseCount.value
        for line in timeLines.value {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            if fields.count == 6, fields[1] == "real", fields[3] == "user", fields[5] == "sys" {
                numbers.resticReal = Double(fields[0]) ?? 0
                numbers.resticUser = Double(fields[2]) ?? 0
                numbers.resticSys = Double(fields[4]) ?? 0
            } else if line.hasSuffix("maximum resident set size") {
                numbers.resticMaxRSS = Int64(fields[0]) ?? 0
            } else if line.hasSuffix("peak memory footprint") {
                numbers.resticPeakFootprint = Int64(fields[0]) ?? 0
            }
        }
        if let additions = collector?.result() {
            print("MEASURE16D \(label): \(BiggestAdditionsText.logLine(additions).prefix(300))")
        }
        return numbers
    }

    private static func selfUsage() -> (user: Double, sys: Double, maxRSS: Int64) {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func seconds(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1e6 }
        return (seconds(usage.ru_utime), seconds(usage.ru_stime), Int64(usage.ru_maxrss)) // bytes on macOS
    }

    private static func footprint() -> Int64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int64(info.phys_footprint) : 0
    }
}
