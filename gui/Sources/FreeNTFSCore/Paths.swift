import Foundation

/// Fixed locations used by install.sh and the scripts in bin/. The GUI only
/// ever talks to the *installed* copies — `ntfs-autowatch --enable` refuses to
/// register anything else anyway (launchd can't run scripts from ~/Desktop,
/// see MISTAKE.md).
public enum Paths {
    public static let binDir = "/usr/local/bin"
    public static let ntfs3g = "/usr/local/bin/ntfs-3g"
    public static let ntfsfix = "/usr/local/bin/ntfsfix"
    public static let ntfsMount = "/usr/local/bin/ntfs-mount"
    public static let ntfsUnmount = "/usr/local/bin/ntfs-unmount"
    public static let ntfsAutowatch = "/usr/local/bin/ntfs-autowatch"
    /// A symlink into FUSE-T's own folder. The Full Disk Access "+" picker
    /// won't accept the symlink — the real file has to be added (MISTAKE.md).
    public static let goNFSv4Link = "/usr/local/bin/go-nfsv4"
    public static let fuseTLibrary = "/usr/local/lib/libfuse-t.dylib"

    // Mirrors LABEL / PLIST / LOG / IGNORE_FILE in bin/ntfs-autowatch.
    public static let daemonLabel = "local.free-ntfs-mac.autowatch"
    public static let daemonPlist = "/Library/LaunchDaemons/local.free-ntfs-mac.autowatch.plist"
    public static let daemonLog = "/var/log/ntfs-autowatch.log"
    public static let ignoreFile = "/usr/local/etc/ntfs-autowatch.ignore"
    // Mirrors LOG in bin/ntfs-mount. Truncated on every run: it only ever
    // describes the most recent mount attempt, manual or automatic.
    public static let mountLog = "/tmp/ntfs-mount.log"

    /// System Settings → Privacy & Security → Full Disk Access.
    /// Checked on macOS 26.6: SecurityPrivacyExtension.appex declares
    /// `legacyBundleIdentifier = com.apple.preference.security` and lists
    /// `revealElementKeyName = Privacy_AllFiles` for
    /// kTCCServiceSystemPolicyAllFiles.
    public static let fullDiskAccessSettingsURL =
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!

    public static let homebrewCandidates = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]

    /// The real go-nfsv4 binary behind the /usr/local/bin symlink (the
    /// version number is in the file name, so it's resolved, not hardcoded).
    public static func resolvedGoNFSv4() -> String? {
        let fm = FileManager.default
        guard let dest = try? fm.destinationOfSymbolicLink(atPath: goNFSv4Link) else {
            return fm.isExecutableFile(atPath: goNFSv4Link) ? goNFSv4Link : nil
        }
        let absolute = dest.hasPrefix("/")
            ? dest
            : (binDir as NSString).appendingPathComponent(dest)
        let resolved = URL(fileURLWithPath: absolute).resolvingSymlinksInPath().path
        return fm.fileExists(atPath: resolved) ? resolved : nil
    }
}
