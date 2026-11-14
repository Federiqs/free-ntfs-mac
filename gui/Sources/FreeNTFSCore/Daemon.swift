import Foundation

/// State of the ntfs-autowatch LaunchDaemon, read without root:
/// `launchctl print system/<label>` works for any user.
public struct DaemonStatus: Equatable {
    public var plistInstalled: Bool
    public var loaded: Bool
    public var state: String?
    public var pid: Int?
    public var lastExitCode: String?
    public var program: String?

    public init(plistInstalled: Bool, loaded: Bool, state: String? = nil, pid: Int? = nil,
                lastExitCode: String? = nil, program: String? = nil) {
        self.plistInstalled = plistInstalled
        self.loaded = loaded
        self.state = state
        self.pid = pid
        self.lastExitCode = lastExitCode
        self.program = program
    }

    public static let unknown = DaemonStatus(plistInstalled: false, loaded: false)

    public var isRunning: Bool { loaded && state == "running" }
}

public enum DaemonInspector {
    /// Parses the top level of `launchctl print system/<label>` (lines with a
    /// single leading tab; nested blocks reuse keys like `state`).
    public static func parse(printOutput text: String, exitStatus: Int32, plistInstalled: Bool) -> DaemonStatus {
        var status = DaemonStatus(plistInstalled: plistInstalled, loaded: false)
        guard exitStatus == 0 else { return status }
        status.loaded = true
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard raw.hasPrefix("\t"), !raw.hasPrefix("\t\t") else { continue }
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let eq = line.range(of: " = ") else { continue }
            let key = String(line[..<eq.lowerBound])
            let value = String(line[eq.upperBound...])
            switch key {
            case "state" where status.state == nil: status.state = value
            case "pid" where status.pid == nil: status.pid = Int(value)
            case "last exit code" where status.lastExitCode == nil: status.lastExitCode = value
            case "program" where status.program == nil: status.program = value
            default: break
            }
        }
        return status
    }

    public static func current() -> DaemonStatus {
        let r = Shell.run("/bin/launchctl", ["print", "system/" + Paths.daemonLabel])
        return parse(printOutput: r.stdout, exitStatus: r.status,
                     plistInstalled: FileManager.default.fileExists(atPath: Paths.daemonPlist))
    }
}

// MARK: - The daemon's log

/// One mount attempt by the daemon, as recorded in /var/log/ntfs-autowatch.log.
public struct MountAttempt: Equatable {
    public enum Outcome: Equatable { case succeeded, failed, inProgress }

    public let label: String
    public let device: String
    public let started: Date
    public var finished: Date?
    public var outcome: Outcome
    /// ntfs-mount's own output for this attempt (on failure it prints the
    /// last lines of /tmp/ntfs-mount.log), which the daemon's stdout captures.
    public var details: [String]

    public init(label: String, device: String, started: Date, finished: Date?,
                outcome: Outcome, details: [String]) {
        self.label = label
        self.device = device
        self.started = started
        self.finished = finished
        self.outcome = outcome
        self.details = details
    }

    /// The raw-device open was refused: Full Disk Access missing for the
    /// binary that tried (MISTAKE.md, "The root LaunchDaemon needs Full Disk
    /// Access granted to the binaries themselves").
    public var permissionDeniedLine: String? {
        details.first(where: AutowatchLog.isPermissionDenied)
    }
}

/// Reads the log written by bin/ntfs-autowatch. Its messages are the script's
/// own (Italian) strings; the markers below are copied from it verbatim, and a
/// unit test checks they still appear in bin/ntfs-autowatch.
public enum AutowatchLog {
    public static let attemptMarker = ": rilevato, lo monto in scrittura..."
    public static let successMarker = ": OK, scrivibile su "
    public static let failureMarker = ": montaggio fallito, "
    public static let startMarker = "ntfs-autowatch avviato ("

    private static let timestamped = try! NSRegularExpression(
        pattern: #"^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}) (.*)$"#)
    private static let attemptLine = try! NSRegularExpression(
        pattern: #"^(.*) \((/dev/\S+)\): rilevato, lo monto in scrittura\.\.\.$"#)

    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    public static func isPermissionDenied(_ line: String) -> Bool {
        line.contains("/dev/") && line.contains("Operation not permitted")
    }

    public struct Summary: Equatable {
        public var attempts: [MountAttempt] = []
        public var lastDaemonStart: Date?
        public var latestAttempt: MountAttempt? { attempts.last }
    }

    public static func parse(_ text: String) -> Summary {
        var summary = Summary()
        var current: MountAttempt?

        func close() {
            if let c = current { summary.attempts.append(c) }
            current = nil
        }

        for raw in text.components(separatedBy: "\n") {
            let ns = raw as NSString
            guard let m = timestamped.firstMatch(in: raw, range: NSRange(location: 0, length: ns.length)),
                  let date = dateFormatter.date(from: ns.substring(with: m.range(at: 1))) else {
                // Untimestamped: ntfs-mount output, belongs to the open attempt.
                if !raw.isEmpty { current?.details.append(raw) }
                continue
            }
            let message = ns.substring(with: m.range(at: 2))

            if message.hasPrefix(startMarker) {
                close()
                summary.lastDaemonStart = date
            } else if let a = attemptLine.firstMatch(in: message, range: NSRange(location: 0, length: (message as NSString).length)) {
                close()
                let mns = message as NSString
                current = MountAttempt(label: mns.substring(with: a.range(at: 1)),
                                       device: mns.substring(with: a.range(at: 2)),
                                       started: date, finished: nil, outcome: .inProgress, details: [])
            } else if var c = current, message.hasPrefix(c.label + successMarker) {
                c.outcome = .succeeded
                c.finished = date
                current = c
                close()
            } else if var c = current, message.hasPrefix(c.label + failureMarker) {
                c.outcome = .failed
                c.finished = date
                current = c
                close()
            }
            // Other timestamped lines ("già montato…", ignore-list notices)
            // aren't attempts.
        }
        close()
        return summary
    }

    /// Reads at most the last `maxBytes` of a file (logs only grow).
    public static func tail(ofFile path: String, maxBytes: Int = 256 * 1024) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd() else { return "" }
        var text = String(decoding: data, as: UTF8.self)
        if start > 0, let nl = text.firstIndex(of: "\n") {
            text = String(text[text.index(after: nl)...]) // drop the partial first line
        }
        return text
    }
}

// MARK: - Full Disk Access, from evidence only

/// There's no API to ask whether another binary has Full Disk Access (the TCC
/// database itself needs Full Disk Access to read). So the app never claims
/// it's granted or missing without evidence: it reports what the daemon's
/// most recent real mount attempt showed.
public enum FullDiskAccessEvidence: Equatable {
    /// The daemon hasn't tried to mount anything yet (in the readable log).
    case untested
    /// Last attempt mounted read-write: the daemon could open the raw device.
    case working(label: String, at: Date)
    /// Last attempt failed opening the device with "Operation not permitted".
    case denied(label: String, at: Date, evidence: String)
    /// Last attempt failed for a reason the log doesn't pin on permissions.
    case failedOtherReason(label: String, at: Date)
    case inProgress(label: String, since: Date)

    public static func assess(_ log: AutowatchLog.Summary,
                              mountLog: String? = nil, mountLogModified: Date? = nil) -> FullDiskAccessEvidence {
        guard let last = log.latestAttempt else { return .untested }
        switch last.outcome {
        case .inProgress:
            return .inProgress(label: last.label, since: last.started)
        case .succeeded:
            return .working(label: last.label, at: last.finished ?? last.started)
        case .failed:
            let at = last.finished ?? last.started
            if let line = last.permissionDeniedLine {
                return .denied(label: last.label, at: at, evidence: line)
            }
            // The daemon log only keeps ntfs-mount's last 6 lines. If
            // /tmp/ntfs-mount.log was written during this same attempt, it
            // has the full output.
            if let text = mountLog, let modified = mountLogModified,
               modified >= last.started.addingTimeInterval(-2),
               modified <= at.addingTimeInterval(2),
               let line = text.components(separatedBy: "\n").first(where: AutowatchLog.isPermissionDenied) {
                return .denied(label: last.label, at: at, evidence: line)
            }
            return .failedOtherReason(label: last.label, at: at)
        }
    }
}
