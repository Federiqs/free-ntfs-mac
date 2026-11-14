import Foundation

public struct InstallStatus: Equatable {
    public var xcodeCommandLineTools: Bool
    public var homebrewPath: String?
    public var fuseT: Bool
    /// `ntfs-3g --version` actually ran (binary present *and* its dylibs load).
    public var ntfs3gRuns: Bool
    public var ntfs3gVersion: String?
    public var missingTools: [String]
    /// nil when ntfs-mount isn't installed or doesn't look like ours.
    public var mountScriptHasMountPointFix: Bool?
    /// Installed scripts whose bytes differ from the copy bundled in the app.
    public var scriptsDifferingFromBundle: [String]

    public init(xcodeCommandLineTools: Bool, homebrewPath: String?, fuseT: Bool, ntfs3gRuns: Bool,
                ntfs3gVersion: String?, missingTools: [String], mountScriptHasMountPointFix: Bool?,
                scriptsDifferingFromBundle: [String]) {
        self.xcodeCommandLineTools = xcodeCommandLineTools
        self.homebrewPath = homebrewPath
        self.fuseT = fuseT
        self.ntfs3gRuns = ntfs3gRuns
        self.ntfs3gVersion = ntfs3gVersion
        self.missingTools = missingTools
        self.mountScriptHasMountPointFix = mountScriptHasMountPointFix
        self.scriptsDifferingFromBundle = scriptsDifferingFromBundle
    }

    public var cliInstalled: Bool { fuseT && ntfs3gRuns && missingTools.isEmpty }

    public static let requiredTools = ["ntfs-3g", "ntfsfix", "ntfs-mount", "ntfs-unmount", "ntfs-autowatch"]
    public static let scripts = ["ntfs-mount", "ntfs-unmount", "ntfs-autowatch"]
}

public enum InstallInspector {
    /// True if bin/ntfs-mount creates the mount point after unmounting macOS's
    /// read-only mount (the 0.2.1 fix). Up to 0.2.0 it did `mkdir` first and
    /// every mount made while the native mount was present failed — which is
    /// always the case for the daemon. nil if the markers aren't found.
    public static func hasMountPointFix(_ script: String) -> Bool? {
        guard let unmount = script.range(of: "diskutil unmount \"$device\""),
              let mkdir = script.range(of: "mkdir -p \"$mountpoint\"") else { return nil }
        return mkdir.lowerBound > unmount.lowerBound
    }

    /// Blocking (runs xcode-select and ntfs-3g --version).
    public static func current(bundledCLI: URL?) -> InstallStatus {
        let fm = FileManager.default
        let clt = Shell.run("/usr/bin/xcode-select", ["-p"]).status == 0
        let brew = Paths.homebrewCandidates.first { fm.isExecutableFile(atPath: $0) }
        let fuseT = fm.fileExists(atPath: Paths.fuseTLibrary)

        var runs = false
        var version: String?
        if fm.isExecutableFile(atPath: Paths.ntfs3g) {
            let r = Shell.run(Paths.ntfs3g, ["--version"], timeout: 10)
            let out = r.combinedOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            runs = r.status == 0 && out.hasPrefix("ntfs-3g")
            version = runs ? out.components(separatedBy: "\n").first : nil
        }

        let missing = InstallStatus.requiredTools.filter {
            !fm.isExecutableFile(atPath: (Paths.binDir as NSString).appendingPathComponent($0))
        }

        let installedMount = try? String(contentsOfFile: Paths.ntfsMount, encoding: .utf8)
        let fix = installedMount.flatMap(hasMountPointFix)

        var differing: [String] = []
        if let bundled = bundledCLI?.appendingPathComponent("bin") {
            for name in InstallStatus.scripts {
                guard let installed = fm.contents(atPath: (Paths.binDir as NSString).appendingPathComponent(name)),
                      let ours = fm.contents(atPath: bundled.appendingPathComponent(name).path) else { continue }
                if installed != ours { differing.append(name) }
            }
        }

        return InstallStatus(xcodeCommandLineTools: clt, homebrewPath: brew, fuseT: fuseT,
                             ntfs3gRuns: runs, ntfs3gVersion: version, missingTools: missing,
                             mountScriptHasMountPointFix: fix,
                             scriptsDifferingFromBundle: differing)
    }
}
