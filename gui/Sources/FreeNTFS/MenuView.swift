import SwiftUI
import FreeNTFSCore

struct MenuView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("free-ntfs-mac").font(.headline)
                Spacer()
                Button { model.refresh(forceInstallCheck: true) } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("Re-check now")
            }

            if let banner = model.banner {
                BannerView(banner: banner) { model.banner = nil }
            }

            if let install = model.install, !install.cliInstalled {
                setupNeeded("The command-line tools aren't installed yet.")
            } else if model.install?.mountScriptHasMountPointFix == false {
                setupNeeded("The installed ntfs-mount predates the 0.2.1 fix: mounts fail while macOS's read-only mount is present. Re-run install.sh.")
            }

            Divider()
            volumes
            if !model.snapshot.otherFuseTMounts.isEmpty {
                otherMounts
            }
            Divider()
            service
            Divider()

            HStack {
                Button("Setup…") { Windows.showSetup(model) }
                Button("Log…") { Windows.showLog(model) }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(12)
        .frame(width: 370)
    }

    private func setupNeeded(_ text: String) -> some View {
        HStack(alignment: .top) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button("Open Setup") { Windows.showSetup(model) }
        }
    }

    @ViewBuilder private var volumes: some View {
        Text("NTFS volumes").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
        if model.snapshot.capturedAt == .distantPast {
            ProgressView().controlSize(.small)
        } else if model.snapshot.volumes.isEmpty {
            Text("No NTFS volume connected.").font(.callout).foregroundStyle(.secondary)
        } else {
            ForEach(model.snapshot.volumes) { volume in
                VolumeRow(volume: volume)
            }
        }
    }

    @ViewBuilder private var otherMounts: some View {
        Text("Other FUSE-T mounts").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
        ForEach(model.snapshot.otherFuseTMounts, id: \.mountPoint) { m in
            HStack {
                VStack(alignment: .leading) {
                    Text(m.mountPoint).font(.callout)
                    Text("Not matched to a connected NTFS volume").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                if let busy = model.busy[m.mountPoint] {
                    ProgressView().controlSize(.small)
                    Text(busy).font(.caption)
                } else if model.cliInstalled {
                    Button("Unmount") {
                        Task { await model.unmount(mountPoint: m.mountPoint, label: m.mountPoint, key: m.mountPoint) }
                    }
                }
            }
        }
    }

    @ViewBuilder private var service: some View {
        let daemon = Describe.daemon(model.snapshot.daemon)
        HStack {
            StatusDot(color: daemon.1)
            Text(daemon.0).font(.callout)
            Spacer()
            if let busy = model.busy["daemon"] {
                ProgressView().controlSize(.small)
                Text(busy).font(.caption)
            } else if model.cliInstalled && !model.snapshot.daemon.plistInstalled {
                Button("Turn On…") { Task { await model.enableAutowatch() } }
            } else if model.snapshot.daemon.plistInstalled && !model.snapshot.daemon.isRunning {
                Button("Fix…") { Windows.showSetup(model) }
            }
        }
        if model.snapshot.daemon.plistInstalled || !model.snapshot.log.attempts.isEmpty {
            let fda = Describe.fullDiskAccess(model.snapshot.fullDiskAccess)
            HStack(alignment: .top) {
                StatusDot(color: fda.1).padding(.top, 4)
                Text(fda.0).font(.caption).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                switch model.snapshot.fullDiskAccess {
                case .denied: Button("Fix…") { Windows.showSetup(model) }
                case .failedOtherReason: Button("Log…") { Windows.showLog(model) }
                default: EmptyView()
                }
            }
        }
    }
}

struct VolumeRow: View {
    @EnvironmentObject var model: AppModel
    let volume: NTFSVolume

    var body: some View {
        let state = Describe.volumeState(volume.state)
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "externaldrive.fill")
                .font(.title2)
                .foregroundStyle(state.1)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(volume.label).font(.body.weight(.semibold))
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: volume.size, countStyle: .file))
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: 5) {
                    StatusDot(color: state.1)
                    Text(state.0).font(.caption)
                    if let mp = volume.state.mountPoint {
                        Text(mp).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }
                Text([volume.deviceNode, volume.busProtocol].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption2).foregroundStyle(.secondary)
                if volume.ignoredByAutowatch {
                    Text("In ntfs-autowatch.ignore: auto-mount leaves it alone.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                actions.padding(.top, 2)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private var actions: some View {
        if let busy = model.busy[volume.id] {
            HStack {
                ProgressView().controlSize(.small)
                Text(busy).font(.caption)
            }
        } else {
            HStack {
                switch volume.state {
                case .readWrite(let mp):
                    Button("Open") { model.openInFinder(mp) }
                    Button("Unmount") {
                        Task { await model.unmount(mountPoint: mp, label: volume.label, key: volume.id) }
                    }
                case .readOnlyNative(let mp), .mountedOther(let mp):
                    Button("Open") { model.openInFinder(mp) }
                    if case .readOnlyNative = volume.state { mountButtons }
                case .notMounted:
                    mountButtons
                }
            }
            .controlSize(.small)
        }
    }

    @ViewBuilder private var mountButtons: some View {
        if model.cliInstalled {
            if model.snapshot.daemon.isRunning && !volume.ignoredByAutowatch {
                Button("Mount Read-Write") { Task { await model.mountViaService(volume) } }
                    .help("Restart the auto-mount service so it mounts this volume (admin password).")
                Button("In Terminal…") { model.mountInTerminal(volume) }
                    .help("Run ntfs-mount \(volume.deviceNode) in Terminal (sudo password).")
            } else {
                Button("Mount Read-Write in Terminal…") { model.mountInTerminal(volume) }
                    .help("Run ntfs-mount \(volume.deviceNode) in Terminal (sudo password).")
            }
        }
    }
}
