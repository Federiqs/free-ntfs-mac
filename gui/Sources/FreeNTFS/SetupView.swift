import SwiftUI
import FreeNTFSCore

struct SetupView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Set up read-write NTFS").font(.title2.weight(.semibold))
                    Text("Three steps. The second one has to be done by hand in System Settings: macOS lets no app, including this one, grant disk access for you.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let banner = model.banner {
                    BannerView(banner: banner) { model.banner = nil }
                }

                StepCard(number: 1, title: "Install the command-line tools", status: installStatus) {
                    InstallStep()
                }
                StepCard(number: 2, title: "Grant Full Disk Access (one time, by hand)", status: fdaStatus) {
                    FullDiskAccessStep()
                }
                StepCard(number: 3, title: "Turn on auto-mount", status: daemonStatus) {
                    AutoMountStep()
                }

                HStack {
                    Spacer()
                    Button("Re-check Everything") { model.refresh(forceInstallCheck: true) }
                }
            }
            .padding(20)
        }
        .frame(minWidth: 560, minHeight: 500)
    }

    private var installStatus: StepStatus {
        guard let i = model.install else { return .unverified }
        if i.mountScriptHasMountPointFix == false { return .problem }
        return i.cliInstalled ? .done : .todo
    }

    /// Only "done" with evidence: a successful mount by the service.
    private var fdaStatus: StepStatus {
        switch model.snapshot.fullDiskAccess {
        case .working: return .done
        case .denied: return .problem
        default: return .unverified
        }
    }

    private var daemonStatus: StepStatus {
        let d = model.snapshot.daemon
        if d.isRunning { return .done }
        if d.plistInstalled || d.loaded { return .problem }  // installed, yet not running
        return .todo
    }
}

enum StepStatus { case done, todo, problem, unverified }

struct StepCard<Content: View>: View {
    let number: Int
    let title: String
    let status: StepStatus
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("\(number)")
                    .font(.headline)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Color.accentColor.opacity(0.15)))
                Text(title).font(.headline)
                Spacer()
                switch status {
                case .done: Label("Done", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                case .todo: Label("To do", systemImage: "circle").foregroundStyle(.secondary)
                case .problem: Label("Needs attention", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                case .unverified: Label("Not verified", systemImage: "questionmark.circle").foregroundStyle(.secondary)
                }
            }
            content
        }
        .padding(14)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct Check: View {
    let ok: Bool?
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            switch ok {
            case .some(true): Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .some(false): Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
            case .none: Image(systemName: "questionmark.circle").foregroundStyle(.secondary)
            }
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout)
    }
}

private struct InstallStep: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if let i = model.install {
            VStack(alignment: .leading, spacing: 4) {
                Check(ok: i.xcodeCommandLineTools, text: "Xcode Command Line Tools")
                Check(ok: i.homebrewPath != nil, text: "Homebrew" + (i.homebrewPath.map { " (\($0))" } ?? ""))
                Check(ok: i.fuseT, text: "FUSE-T (\(Paths.fuseTLibrary))")
                Check(ok: i.ntfs3gRuns, text: i.ntfs3gVersion ?? "ntfs-3g (\(Paths.ntfs3g))")
                Check(ok: i.missingTools.isEmpty,
                      text: i.missingTools.isEmpty ? "ntfsfix, ntfs-mount, ntfs-unmount, ntfs-autowatch in \(Paths.binDir)"
                                                   : "Missing from \(Paths.binDir): " + i.missingTools.joined(separator: ", "))
                if let fix = i.mountScriptHasMountPointFix {
                    Check(ok: fix, text: fix ? "ntfs-mount includes the 0.2.1 mount-point fix"
                                             : "ntfs-mount is older than 0.2.1: mounts fail while macOS's read-only mount is present. Re-run install.sh.")
                }
                if !i.scriptsDifferingFromBundle.isEmpty {
                    Text("Note: the installed \(i.scriptsDifferingFromBundle.joined(separator: ", ")) differ from the copy bundled with this app. Re-running install.sh installs the bundled copy.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Text("install.sh runs in a Terminal window, not behind a password popup: Homebrew refuses to run as root, so the script installs packages as you and asks for your password itself, once.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                if !i.xcodeCommandLineTools {
                    Button("Install Command Line Tools…") { model.installXcodeCommandLineTools() }
                }
                if i.homebrewPath == nil {
                    Link("Get Homebrew (brew.sh)", destination: URL(string: "https://brew.sh")!)
                }
                Button(i.cliInstalled ? "Re-run install.sh in Terminal…" : "Run install.sh in Terminal…") {
                    model.runInstallInTerminal()
                }
                .disabled(!i.xcodeCommandLineTools || i.homebrewPath == nil || model.bundledCLI == nil)
            }
            if model.bundledCLI == nil {
                Text("This copy of the app was built without the bundled scripts. Use gui/build-app.sh, or run ./install.sh from the repository.")
                    .font(.caption).foregroundStyle(.orange)
            }
        } else {
            ProgressView().controlSize(.small)
        }
    }
}

private struct FullDiskAccessStep: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Text("The auto-mount service runs in the background, so it doesn't inherit Terminal's disk access. macOS only lets it open the drive if ntfs-3g and ntfsfix are on the Full Disk Access list. Without that, every automatic mount fails with \"Operation not permitted\".")
            .fixedSize(horizontal: false, vertical: true)

        VStack(alignment: .leading, spacing: 6) {
            Text("1. Click **Open Full Disk Access**.")
            Text("2. Click **Show ntfs-3g and ntfsfix in Finder**: a Finder window opens with both files selected.")
            Text("3. Drag both files from Finder into the Full Disk Access list. Make sure both switches are on (macOS asks for your password).")
            Text("4. If the service still can't open the drive, add FUSE-T's go-nfsv4 the same way. It was on the list in the verified working setup, but whether it's actually required hasn't been tested.")
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)

        HStack {
            Button("Open Full Disk Access") { model.openFullDiskAccessSettings() }
            Button("Show ntfs-3g and ntfsfix in Finder") { model.revealBinariesInFinder() }
                .disabled(!model.cliInstalled)
            Button("Show go-nfsv4") { model.revealGoNFSv4InFinder() }
        }
        Button("Copy the paths") {
            var paths = [Paths.ntfs3g, Paths.ntfsfix]
            if let go = Paths.resolvedGoNFSv4() { paths.append(go) }
            model.copyToPasteboard(paths.joined(separator: "\n"))
        }
        .buttonStyle(.link)

        Divider()
        let fda = Describe.fullDiskAccess(model.snapshot.fullDiskAccess)
        HStack(alignment: .top) {
            StatusDot(color: fda.1).padding(.top, 5)
            VStack(alignment: .leading, spacing: 4) {
                Text(fda.0).font(.callout)
                Text("No app can read another program's Full Disk Access setting, so this is based only on the service's most recent mount attempt in its log.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if case .denied(_, _, let evidence) = model.snapshot.fullDiskAccess {
                    Text(evidence).font(.caption.monospaced()).textSelection(.enabled)
                }
            }
        }
        TestMountHint()
    }
}

/// Offers to verify steps 2-3 with a real mount, when that's possible.
private struct TestMountHint: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let candidates = model.snapshot.volumesADaemonRestartWouldMount
        if model.snapshot.daemon.isRunning, let first = candidates.first {
            HStack {
                Text("To check it now, let the service mount \(first.label):").font(.callout)
                Button("Mount \(first.label) via the Service") { Task { await model.mountViaService(first) } }
                    .disabled(model.busy[first.id] != nil)
            }
        } else if !model.snapshot.daemon.isRunning {
            Text("This gets verified once auto-mount (step 3) is on and mounts a drive.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct AutoMountStep: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Text("A small root LaunchDaemon (ntfs-autowatch) checks for NTFS drives every 3 seconds and mounts each one read-write about 5 seconds after you plug it in, with no Terminal and no password. Each volume is handled once per plug-in: unmount it and it stays unmounted until you reconnect the drive. Volume names listed in \(Paths.ignoreFile) are never touched.")
            .fixedSize(horizontal: false, vertical: true)

        let d = Describe.daemon(model.snapshot.daemon)
        HStack {
            StatusDot(color: d.1)
            Text(d.0)
            if let pid = model.snapshot.daemon.pid { Text("pid \(pid)").foregroundStyle(.secondary) }
        }
        .font(.callout)

        HStack {
            if let busy = model.busy["daemon"] {
                ProgressView().controlSize(.small)
                Text(busy)
            } else if model.snapshot.daemon.plistInstalled || model.snapshot.daemon.loaded {
                if !model.snapshot.daemon.isRunning {
                    // --enable boots out and re-bootstraps the job.
                    Button("Turn On Again") { Task { await model.enableAutowatch() } }
                        .disabled(!model.cliInstalled)
                }
                Button("Turn Off Auto-mount") { Task { await model.disableAutowatch() } }
            } else {
                Button("Turn On Auto-mount") { Task { await model.enableAutowatch() } }
                    .disabled(!model.cliInstalled)
            }
            Spacer()
            Button("Open Log…") { Windows.showLog(model) }
        }
        Text("Turning it on or off asks for your admin password (runs ntfs-autowatch --enable / --disable). That's fine for a popup: installing a LaunchDaemon doesn't open any disk.")
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
