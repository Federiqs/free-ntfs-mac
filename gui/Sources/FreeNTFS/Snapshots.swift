import SwiftUI
import AppKit
import FreeNTFSCore

/// `FreeNTFS --render-snapshots <dir>`: renders the menu and setup views to
/// PNGs offscreen — the live state plus a few made-up ones (a fresh Mac,
/// Full Disk Access denied) — so the UI can be reviewed without clicking
/// through real, privileged actions. Development aid; nothing is executed.
@MainActor
enum SnapshotRenderer {
    static func run(outputDirectory: URL) {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let live = SystemSnapshot.capture()
        let liveInstall = InstallInspector.current(bundledCLI: Bundle.main.resourceURL?.appendingPathComponent("cli"))

        let roVolume = NTFSVolume(deviceIdentifier: "disk4s2", volumeName: "Passport", size: 1_000_202_043_392,
                                  busProtocol: "USB", isInternal: false,
                                  state: .readOnlyNative(mountPoint: "/Volumes/Passport"), ignoredByAutowatch: false)
        let freshInstall = InstallStatus(xcodeCommandLineTools: true, homebrewPath: "/opt/homebrew/bin/brew",
                                         fuseT: false, ntfs3gRuns: false, ntfs3gVersion: nil,
                                         missingTools: InstallStatus.requiredTools,
                                         mountScriptHasMountPointFix: nil, scriptsDifferingFromBundle: [])
        var fresh = SystemSnapshot.empty
        fresh.volumes = [roVolume]
        fresh.capturedAt = Date()

        let attemptDate = Date().addingTimeInterval(-300)
        let deniedLine = "Error opening '/dev/disk4s2': Operation not permitted"
        var denied = fresh
        denied.daemon = DaemonStatus(plistInstalled: true, loaded: true, state: "running", pid: 4242)
        denied.fullDiskAccess = .denied(label: "Passport", at: attemptDate, evidence: deniedLine)
        denied.log.attempts = [MountAttempt(label: "Passport", device: "/dev/disk4s2", started: attemptDate,
                                            finished: attemptDate, outcome: .failed, details: [deniedLine])]
        var stopped = denied
        stopped.daemon = DaemonStatus(plistInstalled: true, loaded: false)
        stopped.fullDiskAccess = .untested
        stopped.log.attempts = []

        let scenarios: [(String, SystemSnapshot, InstallStatus, Banner?)] = [
            ("live", live, liveInstall, nil),
            ("fresh-mac", fresh, freshInstall, nil),
            ("fda-denied", denied, liveInstall,
             Banner(kind: .failure, title: "Mount failed: Full Disk Access is missing",
                    detail: "The service couldn't open the disk:\n\(deniedLine)\n\nGrant Full Disk Access (Setup, step 2), then try again.")),
            ("service-stopped", stopped, liveInstall, nil),
        ]

        for (name, snapshot, install, banner) in scenarios {
            let model = AppModel()
            model.setStateForSnapshot(snapshot, install: install, banner: banner)
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                let suffix = appearance == .aqua ? "" : "-dark"
                render(MenuView().environmentObject(model), width: 370, height: nil, appearance: appearance,
                       to: outputDirectory.appendingPathComponent("menu-\(name)\(suffix).png"))
                if appearance == .aqua {
                    render(SetupView().environmentObject(model), width: 620, height: 1250, appearance: appearance,
                           to: outputDirectory.appendingPathComponent("setup-\(name).png"))
                }
            }
        }
        render(LogView(), width: 760, height: 520, appearance: .aqua,
               to: outputDirectory.appendingPathComponent("log-live.png"))
        print("Wrote snapshots to \(outputDirectory.path)")
    }

    private static func render<V: View>(_ view: V, width: CGFloat, height: CGFloat?,
                                        appearance: NSAppearance.Name, to url: URL) {
        let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
        host.appearance = NSAppearance(named: appearance)
        let size = NSSize(width: width, height: height ?? max(host.fittingSize.height, 100))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        // Let SwiftUI finish a layout pass.
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
