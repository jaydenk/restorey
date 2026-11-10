import Darwin

/// What the kernel reports for one live process: its parent and when it started. The start time is
/// what tells a process apart from a later one that reuses its pid.
public struct KernelProcessInfo: Sendable, Equatable {
    public struct StartTime: Sendable, Hashable {
        public let seconds: Int
        public let microseconds: Int32

        public init(seconds: Int, microseconds: Int32) {
            self.seconds = seconds
            self.microseconds = microseconds
        }
    }

    public let parentPID: pid_t
    public let startTime: StartTime

    public init(parentPID: pid_t, startTime: StartTime) {
        self.parentPID = parentPID
        self.startTime = startTime
    }
}

/// `sysctl(CTL_KERN, KERN_PROC, KERN_PROC_PID, pid)`: `kp_eproc.e_ppid` and `kp_proc.p_starttime`.
/// Nil when no such process exists (including one that has exited and been reaped) or the call fails.
public func processInfo(pid: pid_t) -> KernelProcessInfo? {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    let result = mib.withUnsafeMutableBufferPointer { mib in
        sysctl(mib.baseAddress, u_int(mib.count), &info, &size, nil, 0)
    }
    // A pid with no process succeeds with size 0.
    guard result == 0, size == MemoryLayout<kinfo_proc>.stride, info.kp_proc.p_pid == pid else { return nil }
    let start = info.kp_proc.p_un.__p_starttime
    return KernelProcessInfo(
        parentPID: info.kp_eproc.e_ppid,
        startTime: .init(seconds: Int(start.tv_sec), microseconds: start.tv_usec))
}
