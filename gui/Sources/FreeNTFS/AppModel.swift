import SwiftUI
import AppKit
import FreeNTFSCore

struct Banner: Identifiable, Equatable {
    enum Kind { case success, failure, info }
    let id = UUID()
    let kind: Kind
    let title: String
    let detail: String?
}

/// Holds the latest read-only snapshot and runs actions. Every action ends by
/// re-reading the real state and reporting *that* — a script exiting 0 is
/// never taken as proof (ntfs-3g itself exits 0 on some failed mounts, see
/// MISTAKE.md).
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var snapshot: SystemSnapshot = .empty
    @Published private(set) var install: InstallStatus?
    /// Keyed by volume id, or "daemon".
    @Published private(set) var busy: [String: String] = [:]
    @Published var banner: Banner?

    /// The copy of install.sh + bin/ + patches/ that build-app.sh puts in
    /// Contents/Resources/cli. nil when running an unbundled binary.
    let bundledCLI: URL?

    private var timer: Timer?
    private var refreshing = false
    private var lastInstallCheck = Date.distantPast

    init() {
        let candidate = Bundle.main.resourceURL?.appendingPathComponent("cli")
        if let c = candidate, FileManager.default.fileExists(atPath: c.appendingPathComponent("install.sh").path) {
            bundledCLI = c
        } else {
            bundledCLI = nil
        }
    }

    // MARK: Refresh

    func start() {
        refresh(forceInstallCheck: true)
        // Same cadence as ntfs-autowatch's own diskutil polling.
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh(forceInstallCheck: Bool = false) {
        guard !refreshing else { return }
        refreshing = true
        let checkInstall = forceInstallCheck || Date().timeIntervalSince(lastInstallCheck) > 15
        let cli = bundledCLI
        Task.detached(priority: .utility) {
            let snap = SystemSnapshot.capture()
            let inst = checkInstall ? InstallInspector.current(bundledCLI: cli) : nil
            await MainActor.run {
                self.snapshot = snap
                if let inst {
                    self.install = inst
                    self.lastInstallCheck = Date()
                }
                self.refreshing = false
            }
        }
    }

    /// Re-reads the state right now and returns it (used to verify actions).
    @discardableResult
    func reload() async -> SystemSnapshot {
        let snap = await Task.detached(priority: .userInitiated) { SystemSnapshot.capture() }.value
        snapshot = snap
        return snap
    }

    /// For `--render-snapshots` only: show a given state without polling.
    func setStateForSnapshot(_ snapshot: SystemSnapshot, install: InstallStatus?, banner: Banner? = nil) {
        self.snapshot = snapshot
        self.install = install
        self.banner = banner
    }

    var cliInstalled: Bool { install?.cliInstalled ?? false }

    var menuBarSymbol: String {
        if let install, !install.cliInstalled { return "externaldrive.badge.questionmark" }
        if hasProblem { return "externaldrive.badge.exclamationmark" }
        if snapshot.volumes.contains(where: { $0.state.isReadWrite }) { return "externaldrive.badge.checkmark" }
        return "externaldrive"
    }

    /// Something the user should look at, shown as a warning in the menu bar.
    var hasProblem: Bool {
        if case .denied = snapshot.fullDiskAccess { return true }
        if snapshot.daemon.plistInstalled && !snapshot.daemon.isRunning { return true }
        if install?.mountScriptHasMountPointFix == false { return true }
        return false
    }

    // MARK: Elevation helpers

    private func elevated(_ command: String, prompt: String) async -> AdminRunner.Outcome {
        await Task.detached(priority: .userInitiated) {
            AdminRunner.run(command, prompt: prompt)
        }.value
    }

    private func openInTerminal(name: String, contents: String) -> Bool {
        do {
            let url = try Commands.writeCommandFile(named: name, contents: contents)
            if NSWorkspace.shared.open(url) { return true }
            banner = Banner(kind: .failure, title: "Couldn't open Terminal",
                            detail: "macOS refused to open \(url.path).")
        } catch {
            banner = Banner(kind: .failure, title: "Couldn't write the Terminal script",
                            detail: error.localizedDescription)
        }
        return false
    }

    // MARK: Setup actions

    func runInstallInTerminal() {
        guard let cli = bundledCLI else {
            banner = Banner(kind: .failure, title: "This build has no bundled install.sh",
                            detail: "Build the app with gui/build-app.sh, or run ./install.sh from the repository in Terminal.")
            return
        }
        if openInTerminal(name: "install", contents: Commands.terminalInstallScript(cliDirectory: cli.path)) {
            banner = Banner(kind: .info, title: "install.sh is running in Terminal",
                            detail: "It asks for your password there and takes a few minutes. This window re-checks on its own.")
        }
    }

    func installXcodeCommandLineTools() {
        Task.detached { Shell.run("/usr/bin/xcode-select", ["--install"]) }
        banner = Banner(kind: .info, title: "Apple's Command Line Tools installer should open",
                        detail: "Finish it, then come back here.")
    }

    func enableAutowatch() async {
        busy["daemon"] = "Turning on auto-mount…"
        defer { busy["daemon"] = nil }
        let outcome = await elevated(Commands.enableAutowatch(),
                                     prompt: "FreeNTFS wants to install and start the free-ntfs-mac auto-mount service.")
        let snap = await reload()
        switch outcome {
        case .cancelled:
            return
        case .failed(_, let message):
            banner = Banner(kind: .failure, title: "ntfs-autowatch --enable failed", detail: message)
        case .succeeded(let output):
            if snap.daemon.isRunning {
                banner = Banner(kind: .success, title: "Auto-mount is on",
                                detail: "launchd reports the service running (pid \(snap.daemon.pid.map(String.init) ?? "?")). "
                                    + "Whether it can open your drive is only known after its first mount attempt.")
            } else {
                banner = Banner(kind: .failure, title: "The service isn't running",
                                detail: "ntfs-autowatch --enable finished, but launchd reports state: \(snap.daemon.state ?? "not loaded").\n\(output)")
            }
        }
    }

    func disableAutowatch() async {
        busy["daemon"] = "Turning off auto-mount…"
        defer { busy["daemon"] = nil }
        let outcome = await elevated(Commands.disableAutowatch(),
                                     prompt: "FreeNTFS wants to stop and remove the free-ntfs-mac auto-mount service.")
        let snap = await reload()
        switch outcome {
        case .cancelled:
            return
        case .failed(_, let message):
            banner = Banner(kind: .failure, title: "ntfs-autowatch --disable failed", detail: message)
        case .succeeded:
            if !snap.daemon.loaded && !snap.daemon.plistInstalled {
                banner = Banner(kind: .success, title: "Auto-mount is off",
                                detail: "Volumes already mounted stay mounted.")
            } else {
                banner = Banner(kind: .failure, title: "The service is still there",
                                detail: "launchd: \(snap.daemon.loaded ? "loaded" : "not loaded"), plist \(snap.daemon.plistInstalled ? "present" : "absent").")
            }
        }
    }

    func openFullDiskAccessSettings() {
        if !NSWorkspace.shared.open(Paths.fullDiskAccessSettingsURL) {
            banner = Banner(kind: .failure, title: "Couldn't open System Settings",
                            detail: "Open it yourself: System Settings → Privacy & Security → Full Disk Access.")
        }
    }

    func revealBinariesInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting(
            [Paths.ntfs3g, Paths.ntfsfix].map { URL(fileURLWithPath: $0) })
    }

    func revealGoNFSv4InFinder() {
        guard let path = Paths.resolvedGoNFSv4() else {
            banner = Banner(kind: .failure, title: "go-nfsv4 not found",
                            detail: "\(Paths.goNFSv4Link) doesn't point to an existing file. Is FUSE-T installed?")
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: Volume actions

    /// Restart the root daemon so it mounts the volume itself. Raw disk access
    /// happens inside the daemon (the verified path); only `launchctl
    /// kickstart` goes through the password popup.
    func mountViaService(_ volume: NTFSVolume) async {
        let others = snapshot.volumesADaemonRestartWouldMount.filter { $0.id != volume.id }
        var message = "FreeNTFS restarts the auto-mount service (one admin password prompt). "
            + "About 5 seconds later it mounts \(volume.label) read-write with ntfs-mount."
        if !others.isEmpty {
            message += "\n\nIt will also mount these connected volumes, which aren't read-write right now: "
                + others.map(\.label).joined(separator: ", ")
                + ". Add a volume's name to \(Paths.ignoreFile) to keep the service away from it."
        }
        guard Windows.confirm("Mount \(volume.label) read-write?", message, confirmTitle: "Restart Service and Mount") else { return }

        busy[volume.id] = "Restarting the auto-mount service…"
        defer { busy[volume.id] = nil }
        // The daemon's log has 1-second timestamps.
        let requested = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        switch await elevated(Commands.restartAutowatch(),
                              prompt: "FreeNTFS wants to restart the free-ntfs-mac auto-mount service so it mounts \(volume.label).") {
        case .cancelled:
            return
        case .failed(_, let message):
            banner = Banner(kind: .failure, title: "Couldn't restart the auto-mount service", detail: message)
            return
        case .succeeded:
            break
        }

        busy[volume.id] = "Waiting for the service to mount it…"
        // 5s settle + ntfs-mount's 1s delay and up-to-5s poll, plus margin.
        let deadline = Date().addingTimeInterval(40)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            let snap = await reload()
            if let v = snap.volumes.first(where: { $0.label == volume.label }), v.state.isReadWrite {
                banner = Banner(kind: .success, title: "\(volume.label) is mounted read-write",
                                detail: "Confirmed in the mount table at \(v.expectedMountPoint).")
                return
            }
            if let attempt = snap.log.attempts.last(where: { $0.label == volume.label && $0.started >= requested.addingTimeInterval(-1) }),
               attempt.outcome == .failed {
                banner = failureBanner(for: attempt)
                return
            }
        }
        banner = Banner(kind: .failure, title: "\(volume.label) isn't mounted read-write after 40 seconds",
                        detail: "The service didn't log a result for it. Open the log to see what it did.")
    }

    private func failureBanner(for attempt: MountAttempt) -> Banner {
        if let line = attempt.permissionDeniedLine {
            return Banner(kind: .failure, title: "Mount failed: Full Disk Access is missing",
                          detail: "The service couldn't open the disk:\n\(line)\n\nGrant Full Disk Access (Setup, step 2), then try again.")
        }
        let tail = attempt.details.suffix(6).joined(separator: "\n")
        return Banner(kind: .failure, title: "The service failed to mount \(attempt.label)",
                      detail: (tail.isEmpty ? "" : tail + "\n\n")
                        + "Full details: /tmp/ntfs-mount.log, and FUSE-T's own log at /var/root/Library/Logs/fuse-t/fuse-t.log (readable with sudo).")
    }

    /// The manual path: Terminal + ntfs-mount's own sudo re-exec.
    func mountInTerminal(_ volume: NTFSVolume) {
        guard let script = Commands.terminalMountScript(deviceIdentifier: volume.deviceIdentifier) else {
            banner = Banner(kind: .failure, title: "Unexpected device name", detail: volume.deviceIdentifier)
            return
        }
        guard openInTerminal(name: "mount-\(volume.deviceIdentifier)", contents: script) else { return }
        banner = Banner(kind: .info, title: "Mounting \(volume.label) in Terminal",
                        detail: "Type your Mac password in the Terminal window. This menu shows the result once it's in the mount table.")
        let label = volume.label
        Task {
            let deadline = Date().addingTimeInterval(120)
            while Date() < deadline {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                let snap = await reload()
                if snap.volumes.first(where: { $0.label == label })?.state.isReadWrite == true {
                    banner = Banner(kind: .success, title: "\(label) is mounted read-write",
                                    detail: "Confirmed in the mount table at /Volumes/\(label).")
                    return
                }
            }
            // No claim either way: the user may simply not have typed the password.
        }
    }

    /// The manual path: Terminal + ntfs-unmount's own sudo re-exec. Verified
    /// live that the admin popup denies this too (see Commands.terminalUnmountScript) —
    /// unmounting isn't a raw-disk operation, but the popup's elevation path
    /// is denied it anyway. Don't route this through `elevated(_:prompt:)`.
    func unmount(mountPoint: String, label: String, key: String) async {
        guard let script = Commands.terminalUnmountScript(mountPoint: mountPoint) else { return }
        guard openInTerminal(name: "unmount-\(key)", contents: script) else { return }
        busy[key] = "Unmounting… (type your password in Terminal)"
        defer { busy[key] = nil }
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            let snap = await reload()
            let stillMounted = MountTable.current().contains { $0.isFuseT && $0.mountPoint == mountPoint }
            if !stillMounted {
                var detail = "It's no longer in the mount table."
                if snap.daemon.isRunning {
                    detail += " Auto-mount won't remount it until the drive is reconnected (or you press Mount)."
                }
                banner = Banner(kind: .success, title: "\(label) unmounted", detail: detail)
                return
            }
        }
        // No claim either way: the user may not have typed the password yet,
        // or closed the Terminal window.
    }

    func openInFinder(_ path: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }
}
