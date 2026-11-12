import Darwin

/// Whether a restic from this app's own bundle is running under the agent, for the app to check before an
/// undrained `unregister()`, which would kill it mid-run (Ruling R68).
///
/// The agent can't be asked (it isn't answering), and `SMAppService` doesn't give its pid, so this reads
/// the kernel's process table: every process whose executable is `<app>/Contents/Helpers/restic`
/// (`proc_listallpids`, `proc_pidpath` in libproc) and whose parent's executable is inside the same
/// `Contents/Helpers/` (the agent, `KERN_PROC_PID`'s `e_ppid`). The agent is the only thing that starts
/// that restic, so both paths together identify a backup step in progress without parsing `launchctl`
/// output. A process this user can't inspect is skipped; the agent and restic run as the same user.
///
/// - Parameter helpersPrefix: `<app>/Contents/Helpers/`, with the trailing slash (`InstalledCopy.helpersPrefix`).
public func resticRunsUnderAgent(helpersPrefix: String) -> Bool {
    // `proc_pidpath` reports the path with symlinks resolved (`/private/var`, not `/var`), so compare with
    // the folder's real path.
    let given = helpersPrefix.hasSuffix("/") ? String(helpersPrefix.dropLast()) : helpersPrefix
    guard let real = realpath(given, nil) else { return false }
    let directory = String(cString: real) + "/"
    free(real)
    let restic = directory + "restic"
    for pid in allProcessIDs() where executablePath(of: pid) == restic {
        guard let parent = processInfo(pid: pid)?.parentPID, let path = executablePath(of: parent) else { continue }
        if path.hasPrefix(directory) { return true }
    }
    return false
}

/// Every pid the kernel lists now. Asked once for the count, with room for a few more that start meanwhile.
private func allProcessIDs() -> [pid_t] {
    let count = proc_listallpids(nil, 0)
    guard count > 0 else { return [] }
    var pids = [pid_t](repeating: 0, count: Int(count) + 64)
    let filled = pids.withUnsafeMutableBufferPointer { buffer in
        proc_listallpids(buffer.baseAddress, Int32(buffer.count * MemoryLayout<pid_t>.stride))
    }
    guard filled > 0 else { return [] }
    return Array(pids.prefix(Int(filled))).filter { $0 > 0 }
}

/// The process's executable path, or nil when it has gone or can't be read.
private func executablePath(of pid: pid_t) -> String? {
    var buffer = [CChar](repeating: 0, count: Int(4 * MAXPATHLEN))
    let length = buffer.withUnsafeMutableBufferPointer { proc_pidpath(pid, $0.baseAddress, UInt32($0.count)) }
    guard length > 0 else { return nil }
    return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
}
