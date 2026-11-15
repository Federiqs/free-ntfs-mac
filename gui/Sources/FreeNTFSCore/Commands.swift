import Foundation

/// Every command the app can run, built in one place so they can be printed
/// (`FreeNTFS --print-commands`) and tested without running anything.
///
/// Which privilege path each one takes is the whole point (MISTAKE.md):
/// - Anything that opens /dev/diskN (mounting) runs either inside the root
///   LaunchDaemon or in Terminal under a real `sudo` — never behind the GUI
///   admin-password popup, which macOS denies raw disk access.
/// - Setup steps that don't touch a raw disk use the popup.
/// - install.sh runs in Terminal because Homebrew refuses to run as root; the
///   script asks for sudo itself.
public enum Commands {
    // MARK: Validation

    /// `disk15s2`-style identifiers only — never pass anything else to a shell.
    public static func isValidDeviceIdentifier(_ s: String) -> Bool {
        s.range(of: #"^disk[0-9]+(s[0-9]+)*$"#, options: .regularExpression) != nil
    }

    /// Mount points the app may ask ntfs-unmount to unmount: absolute, single
    /// line, and actually a FUSE-T mount (the caller checks that part).
    public static func isSafeMountPoint(_ s: String) -> Bool {
        s.hasPrefix("/") && !s.contains("\n") && !s.contains("\r") && !s.contains("\0")
    }

    // MARK: Admin popup (no raw disk access involved)

    public static func enableAutowatch() -> String {
        Shell.quote(Paths.ntfsAutowatch) + " --enable 2>&1"
    }

    public static func disableAutowatch() -> String {
        Shell.quote(Paths.ntfsAutowatch) + " --disable 2>&1"
    }

    /// Restarts the daemon. It starts with empty "already handled" state, so
    /// 5s later (its SETTLE delay) it hands every connected NTFS volume that
    /// isn't already read-write — and isn't on the ignore list — to
    /// ntfs-mount. The raw-disk work happens inside the daemon, which is the
    /// path verified on real hardware. AbandonProcessGroup in its plist keeps
    /// existing mounts alive across the restart.
    public static func restartAutowatch() -> String {
        "/bin/launchctl kickstart -k " + Shell.quote("system/" + Paths.daemonLabel) + " 2>&1"
    }

    /// ntfs-unmount does `umount -f` on the FUSE-T NFS mount — no raw device.
    public static func unmount(mountPoint: String) -> String? {
        guard isSafeMountPoint(mountPoint) else { return nil }
        return Shell.quote(Paths.ntfsUnmount) + " " + Shell.quote(mountPoint) + " 2>&1"
    }

    // MARK: Terminal (.command files)

    private static func commandFile(header: String, body: [String]) -> String {
        (["#!/bin/bash",
          "# Written by FreeNTFS.app. " + header,
          "rm -f \"$0\"   # one-shot: bash keeps reading from the open file",
          "clear"] + body).joined(separator: "\n") + "\n"
    }

    /// Runs ntfs-unmount in a real Terminal session, under a real `sudo`.
    /// Verified live: the admin password popup denies this too, not just raw
    /// disk opens — `umount -f` on the FUSE-T NFS mount failed every time
    /// through the popup with "Operation not permitted", and the identical
    /// command worked immediately in a real sudo Terminal session. See
    /// MISTAKE.md.
    public static func terminalUnmountScript(mountPoint: String) -> String? {
        guard let command = unmount(mountPoint: mountPoint) else { return nil }
        return commandFile(
            header: "Unmounts \(mountPoint) with the installed ntfs-unmount.",
            body: [
                "echo " + Shell.quote("free-ntfs-mac: unmounting \(mountPoint)."),
                "echo " + Shell.quote("sudo will ask for your Mac password here (nothing is shown while you type)."),
                "echo",
                command,
                "echo",
                "echo " + Shell.quote("Done. FreeNTFS shows the result in its menu; you can close this window."),
            ])
    }

    /// Runs the installed ntfs-mount for one device in a real Terminal session.
    /// ntfs-mount re-execs itself with sudo there, which is the manual path
    /// README documents (and the one with raw disk access).
    public static func terminalMountScript(deviceIdentifier: String) -> String? {
        guard isValidDeviceIdentifier(deviceIdentifier) else { return nil }
        let dev = "/dev/" + deviceIdentifier
        return commandFile(
            header: "Mounts one NTFS volume read-write with the installed ntfs-mount.",
            body: [
                "echo " + Shell.quote("free-ntfs-mac: mounting \(dev) read-write with ntfs-mount."),
                "echo " + Shell.quote("sudo will ask for your Mac password here (nothing is shown while you type)."),
                "echo",
                Shell.quote(Paths.ntfsMount) + " " + Shell.quote(dev),
                "echo",
                "echo " + Shell.quote("Done. FreeNTFS shows the result in its menu; you can close this window."),
            ])
    }

    /// Runs install.sh from the copy of the repository bundled in the app.
    public static func terminalInstallScript(cliDirectory: String) -> String {
        commandFile(
            header: "Runs free-ntfs-mac's install.sh.",
            body: [
                "cd " + Shell.quote(cliDirectory) + " || exit 1",
                "echo " + Shell.quote("free-ntfs-mac: running install.sh (Homebrew packages, FUSE-T, then an ntfs-3g build)."),
                "echo " + Shell.quote("It asks for your Mac password once, here in Terminal. This takes a few minutes."),
                "echo",
                "/bin/bash ./install.sh",
                "status=$?",
                "echo",
                "if [ \"$status\" -eq 0 ]; then",
                "  echo " + Shell.quote("install.sh finished. Go back to FreeNTFS for the next step; you can close this window."),
                "else",
                "  echo " + Shell.quote("install.sh failed") + " \"(exit status $status)\" " + Shell.quote("- the messages above say where."),
                "fi",
            ])
    }

    /// Writes a .command file to a private temporary folder, mode 0700.
    public static func writeCommandFile(named name: String, contents: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("FreeNTFS", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let url = dir.appendingPathComponent("\(name)-\(UUID().uuidString.prefix(8)).command")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }
}
