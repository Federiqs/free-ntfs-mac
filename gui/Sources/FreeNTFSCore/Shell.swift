import Foundation

public struct CommandResult: Equatable {
    public let status: Int32
    public let stdout: String
    public let stderr: String

    public var combinedOutput: String {
        [stdout, stderr].filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

public enum Shell {
    /// Runs a program directly (no shell), capturing both streams. Blocking —
    /// call it off the main thread.
    @discardableResult
    public static func run(_ executable: String, _ arguments: [String] = [],
                           timeout: TimeInterval = 30) -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do {
            try process.run()
        } catch {
            return CommandResult(status: -1, stdout: "", stderr: "\(executable): \(error.localizedDescription)")
        }

        let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)

        // Drain both pipes concurrently: `diskutil list -plist` alone can
        // exceed the 64KB pipe buffer, and waiting first would deadlock.
        var errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            errData = err.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()
        deadline.cancel()

        return CommandResult(status: process.terminationStatus,
                             stdout: String(decoding: outData, as: UTF8.self),
                             stderr: String(decoding: errData, as: UTF8.self))
    }

    /// POSIX single-quote quoting, safe for any byte sequence except NUL.
    public static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// An AppleScript string literal.
    public static func appleScriptLiteral(_ s: String) -> String {
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"" + escaped + "\""
    }
}

/// The "click to run as admin" password popup:
/// `osascript -e 'do shell script "…" with administrator privileges'`.
///
/// The resulting process is genuinely root, but macOS still denies it raw
/// disk access (proven, MISTAKE.md). It is used here ONLY for steps that never
/// open /dev/diskN: installing/removing the LaunchDaemon, restarting it with
/// launchctl, and `umount -f` of a FUSE-T (NFS loopback) mount. Mounting is
/// never done through this path.
public enum AdminRunner {
    public enum Outcome: Equatable {
        case succeeded(output: String)
        case cancelled
        case failed(status: Int32, message: String)
    }

    /// PATH for `do shell script`, which otherwise gets a minimal one.
    static let path = "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

    /// The AppleScript source that would be passed to osascript. Exposed so it
    /// can be inspected and tested without asking for a password.
    public static func appleScript(for command: String, prompt: String, admin: Bool = true) -> String {
        let full = "export PATH=\(path); " + command
        var script = "do shell script " + Shell.appleScriptLiteral(full)
        if admin {
            script += " with prompt " + Shell.appleScriptLiteral(prompt) + " with administrator privileges"
        }
        return script
    }

    /// Blocking. `admin: false` runs the identical wrapper without elevation —
    /// used by the tests to check quoting end to end.
    public static func run(_ command: String, prompt: String, admin: Bool = true) -> Outcome {
        let script = appleScript(for: command, prompt: prompt, admin: admin)
        let result = Shell.run("/usr/bin/osascript", ["-e", script], timeout: 600)
        if result.status == 0 {
            return .succeeded(output: result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        // "execution error: User canceled. (-128)"
        if result.stderr.contains("(-128)") {
            return .cancelled
        }
        return .failed(status: result.status, message: cleanOsascriptError(result.stderr))
    }

    /// osascript reports a failing `do shell script` as
    /// "0:123: execution error: <output> (<status>)".
    static func cleanOsascriptError(_ stderr: String) -> String {
        var s = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = s.range(of: "execution error: ") {
            s = String(s[r.upperBound...])
        }
        return s
    }
}
