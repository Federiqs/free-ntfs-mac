import Foundation

/// Everything the menu shows, read in one pass. No privileges needed:
/// diskutil, mount, `launchctl print` and the (world-readable) logs.
public struct SystemSnapshot: Equatable {
    public var volumes: [NTFSVolume]
    public var otherFuseTMounts: [MountEntry]
    public var daemon: DaemonStatus
    public var log: AutowatchLog.Summary
    public var fullDiskAccess: FullDiskAccessEvidence
    public var capturedAt: Date

    public static let empty = SystemSnapshot(volumes: [], otherFuseTMounts: [], daemon: .unknown,
                                             log: .init(), fullDiskAccess: .untested,
                                             capturedAt: .distantPast)

    /// Blocking — call off the main thread.
    public static func capture() -> SystemSnapshot {
        let scan = VolumeScanner.scan()
        let daemon = DaemonInspector.current()
        let log = AutowatchLog.parse(AutowatchLog.tail(ofFile: Paths.daemonLog) ?? "")
        let mountLog = try? String(contentsOfFile: Paths.mountLog, encoding: .utf8)
        let mountLogModified = (try? FileManager.default.attributesOfItem(atPath: Paths.mountLog))?[.modificationDate] as? Date
        return SystemSnapshot(volumes: scan.volumes, otherFuseTMounts: scan.otherFuseTMounts,
                              daemon: daemon, log: log,
                              fullDiskAccess: .assess(log, mountLog: mountLog, mountLogModified: mountLogModified),
                              capturedAt: Date())
    }

    /// Volumes a daemon restart would hand to ntfs-mount: not already
    /// read-write, not on the ignore list. (Matches ntfs-autowatch's handle().)
    public var volumesADaemonRestartWouldMount: [NTFSVolume] {
        volumes.filter { !$0.state.isReadWrite && !$0.ignoredByAutowatch }
    }
}

extension SystemSnapshot {
    /// Plain-text report for `FreeNTFS --status`.
    public var report: String {
        var lines: [String] = []
        lines.append("NTFS volumes:")
        if volumes.isEmpty { lines.append("  (none connected)") }
        for v in volumes {
            let state: String
            switch v.state {
            case .notMounted: state = "not mounted"
            case .readOnlyNative(let mp): state = "read-only (macOS) at \(mp)"
            case .readWrite(let mp): state = "read-write (ntfs-3g/FUSE-T) at \(mp)"
            case .mountedOther(let mp): state = "mounted by another driver at \(mp)"
            }
            let ignore = v.ignoredByAutowatch ? " [in ignore list]" : ""
            lines.append("  \(v.label) (\(v.deviceNode), \(ByteCountFormatter.string(fromByteCount: v.size, countStyle: .file)), \(v.busProtocol ?? "?")): \(state)\(ignore)")
        }
        if !otherFuseTMounts.isEmpty {
            lines.append("Other FUSE-T mounts:")
            for m in otherFuseTMounts { lines.append("  \(m.source) on \(m.mountPoint)") }
        }
        lines.append("Auto-mount daemon: plist \(daemon.plistInstalled ? "installed" : "absent"), "
                     + (daemon.loaded ? "loaded, state=\(daemon.state ?? "?"), pid=\(daemon.pid.map(String.init) ?? "-")" : "not loaded"))
        lines.append("Daemon mount attempts in log: \(log.attempts.count)")
        if let a = log.latestAttempt {
            lines.append("  latest: \(a.label) \(a.device) started \(a.started) outcome=\(a.outcome)")
        }
        lines.append("Full Disk Access evidence: \(fullDiskAccess)")
        return lines.joined(separator: "\n")
    }
}
