// SPDX-License-Identifier: MIT
// Copyright (c) 2026 NarNar Labs
// Univocal Connect reference implementation — released under the MIT licence
// (docs/univocal-protocol/LICENSE), independently of the host app's licence.

import Darwin
import Foundation

/// Server-side process → app resolution (SPEC §16.3), public so tests and the probe can
/// reuse it. Public APIs only: `proc_pidinfo(PROC_PIDTBSDINFO)` (falling back to
/// `sysctl(KERN_PROC_PID)`) for the parent pid and `proc_pidpath` for the executable.
/// Never `responsibility_get_pid_responsible_for_pid` (private SPI).
public enum ProcessAncestry {
    /// `[pid, ppid, …]`: the process itself followed by at most `maxHops` ancestors.
    /// Stops before pid 1 (launchd) and pid 0, on a cycle, or when a parent cannot be read.
    /// Empty for `pid <= 0`.
    public static func chain(of pid: pid_t, maxHops: Int = 16) -> [pid_t] {
        guard pid > 0 else { return [] }
        var out: [pid_t] = [pid]
        var current = pid
        for _ in 0..<max(0, maxHops) {
            guard let parent = parentPid(of: current), parent > 1, !out.contains(parent) else { break }
            out.append(parent)
            current = parent
        }
        return out
    }

    /// `proc_pidpath`; `nil` if the process is gone or not inspectable.
    public static func executablePath(of pid: pid_t) -> String? {
        guard pid > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))   // PROC_PIDPATHINFO_MAXSIZE
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        guard n > 0 else { return nil }
        return String(cString: buf)
    }

    /// SPEC §16.3: `true` when the app pid is on the peer's parent chain (ancestry), or when
    /// the executable of any process on that chain lies inside `appBundleURL` (bundle
    /// containment; path-prefix test after standardising and resolving symlinks).
    public static func resolves(peerPid: pid_t, appPid: pid_t?, appBundleURL: URL?) -> Bool {
        let chain = chain(of: peerPid)
        guard !chain.isEmpty else { return false }
        if let appPid, appPid > 1, chain.contains(appPid) { return true }
        guard let appBundleURL else { return false }
        let root = canonical(appBundleURL.path)
        guard root != "/" else { return false }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return chain.contains { pid in
            guard let exe = executablePath(of: pid) else { return false }
            return canonical(exe).hasPrefix(prefix)
        }
    }

    // MARK: Internals

    static func parentPid(of pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        if proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size {
            return pid_t(bitPattern: info.pbi_ppid)
        }
        // Fallback: sysctl(CTL_KERN, KERN_PROC, KERN_PROC_PID, pid) → kp_eproc.e_ppid.
        var kinfo = kinfo_proc()
        var len = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &kinfo, &len, nil, 0) == 0, len > 0, kinfo.kp_proc.p_pid == pid else {
            return nil
        }
        return kinfo.kp_eproc.e_ppid
    }

    static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }
}
