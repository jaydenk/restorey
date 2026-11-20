import Darwin

/// What the process table says about a restic from this app's own bundle running under the agent.
public enum ResticUnderAgent: Sendable, Equatable {
    case running
    case notRunning
    /// The process table couldn't be read, so nothing is known; the sentence says what failed.
    case unknown(String)

    /// Fails closed (fix round 1 of the owner's correction, 20 Nov 2026): a table that can't be read counts as a restic
    /// that may be running, so an automatic re-registration never kills a backup it couldn't see.
    public var mayBeRunning: Bool { self != .notRunning }
}

/// The reads `probeResticUnderAgent` makes, so the decision is tested without real processes. `live` is the kernel's.
public struct ProcessTable: Sendable {
    /// The path with symlinks resolved, or nil when it can't be.
    public var realPath: @Sendable (String) -> String?
    /// Every pid the kernel lists, or nil when the list can't be read.
    public var allProcessIDs: @Sendable () -> [pid_t]?
    /// The process's executable path, or nil when it has gone or can't be read.
    public var executablePath: @Sendable (pid_t) -> String?
    public var parentPID: @Sendable (pid_t) -> pid_t?

    public init(
        realPath: @escaping @Sendable (String) -> String?, allProcessIDs: @escaping @Sendable () -> [pid_t]?,
        executablePath: @escaping @Sendable (pid_t) -> String?, parentPID: @escaping @Sendable (pid_t) -> pid_t?
    ) {
        self.realPath = realPath
        self.allProcessIDs = allProcessIDs
        self.executablePath = executablePath
        self.parentPID = parentPID
    }

    /// `realpath(3)`, `proc_listallpids`, `proc_pidpath` and `KERN_PROC_PID`'s `e_ppid`.
    public static let live = ProcessTable(
        realPath: { path in
            guard let real = realpath(path, nil) else { return nil }
            defer { free(real) }
            return String(cString: real)
        },
        allProcessIDs: liveProcessIDs, executablePath: liveExecutablePath, parentPID: { processInfo(pid: $0)?.parentPID })
}

/// Whether a restic from this app's own bundle is running under the agent, for the app to check before an
/// undrained `unregister()`, which would kill it mid-run (Ruling R68).
///
/// The agent can't be asked (it isn't answering), and `SMAppService` doesn't give its pid, so this reads
/// the kernel's process table: every process whose executable is `<app>/Contents/Helpers/restic`
/// (`proc_listallpids`, `proc_pidpath` in libproc) and whose parent's executable is inside the same
/// `Contents/Helpers/` (the agent, `KERN_PROC_PID`'s `e_ppid`). The agent is the only thing that starts
/// that restic, so both paths together identify a backup step in progress without parsing `launchctl`
/// output. A process this user can't inspect is skipped; the agent and restic run as the same user. When the folder's
/// real path or the process list can't be read, the answer is `.unknown`, which `mayBeRunning` counts as running.
///
/// - Parameter helpersPrefix: `<app>/Contents/Helpers/`, with or without the trailing slash (`InstalledCopy.helpersPrefix`).
public func probeResticUnderAgent(helpersPrefix: String, table: ProcessTable = .live) -> ResticUnderAgent {
    // `proc_pidpath` reports the path with symlinks resolved (`/private/var`, not `/var`), so compare with
    // the folder's real path.
    let given = helpersPrefix.hasSuffix("/") ? String(helpersPrefix.dropLast()) : helpersPrefix
    guard let real = table.realPath(given) else { return .unknown("the real path of \(given) couldn’t be read") }
    guard let pids = table.allProcessIDs() else { return .unknown("the process list couldn’t be read") }
    let directory = real + "/"
    let restic = directory + "restic"
    for pid in pids where table.executablePath(pid) == restic {
        guard let parent = table.parentPID(pid), let path = table.executablePath(parent) else { continue }
        if path.hasPrefix(directory) { return .running }
    }
    return .notRunning
}

/// Every pid the kernel lists now, or nil when it won't list them. Asked once for the count, with room for a few more
/// that start meanwhile.
@Sendable private func liveProcessIDs() -> [pid_t]? {
    let count = proc_listallpids(nil, 0)
    guard count > 0 else { return nil }
    var pids = [pid_t](repeating: 0, count: Int(count) + 64)
    let filled = pids.withUnsafeMutableBufferPointer { buffer in
        proc_listallpids(buffer.baseAddress, Int32(buffer.count * MemoryLayout<pid_t>.stride))
    }
    guard filled > 0 else { return nil }
    return Array(pids.prefix(Int(filled))).filter { $0 > 0 }
}

@Sendable private func liveExecutablePath(of pid: pid_t) -> String? {
    var buffer = [CChar](repeating: 0, count: Int(4 * MAXPATHLEN))
    let length = buffer.withUnsafeMutableBufferPointer { proc_pidpath(pid, $0.baseAddress, UInt32($0.count)) }
    guard length > 0 else { return nil }
    return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
}
