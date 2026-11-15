import SwiftUI
import FreeNTFSCore

struct StatusDot: View {
    let color: Color
    var body: some View {
        Circle().fill(color).frame(width: 8, height: 8)
    }
}

struct BannerView: View {
    let banner: Banner
    let dismiss: () -> Void

    private var color: Color {
        switch banner.kind {
        case .success: return .green
        case .failure: return .red
        case .info: return .blue
        }
    }

    private var symbol: String {
        switch banner.kind {
        case .success: return "checkmark.circle.fill"
        case .failure: return "xmark.octagon.fill"
        case .info: return "info.circle.fill"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 3) {
                Text(banner.title).font(.callout.weight(.semibold))
                if let detail = banner.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            Button(action: dismiss) { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .help("Dismiss")
        }
        .padding(8)
        .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Human-readable descriptions shared by the menu and the setup window.
enum Describe {
    static let time: DateFormatter = {
        let f = DateFormatter()
        // The UI is English; keep "Today" in English but the user's region
        // for the time format.
        f.locale = Locale(identifier: "en_" + (Locale.current.region?.identifier ?? "US"))
        f.dateStyle = .short
        f.timeStyle = .short
        f.doesRelativeDateFormatting = true
        return f
    }()

    static func volumeState(_ state: VolumeState) -> (String, Color) {
        switch state {
        case .readWrite: return ("Read-write (ntfs-3g)", .green)
        case .readOnlyNative: return ("Read-only (macOS)", .orange)
        case .notMounted: return ("Not mounted", .gray)
        case .mountedOther: return ("Mounted by another driver", .blue)
        }
    }

    static func daemon(_ d: DaemonStatus) -> (String, Color) {
        if d.isRunning { return ("Auto-mount: on (service running)", .green) }
        if d.loaded { return ("Auto-mount: loaded but \(d.state ?? "not running")", .orange) }
        if d.plistInstalled { return ("Auto-mount: installed but not loaded", .orange) }
        return ("Auto-mount: off", .gray)
    }

    static func fullDiskAccess(_ e: FullDiskAccessEvidence) -> (String, Color) {
        switch e {
        case .untested:
            return ("Full Disk Access: not verified yet (known after the service's first mount)", .gray)
        case .working(let label, let at):
            return ("Full Disk Access: working, last auto-mount of \(label) succeeded (\(time.string(from: at)))", .green)
        case .denied(let label, let at, _):
            return ("Full Disk Access: missing, the service couldn't open \(label) (\(time.string(from: at)))", .red)
        case .failedOtherReason(let label, let at):
            return ("Last auto-mount of \(label) failed (\(time.string(from: at))), not a permission error in the log", .orange)
        case .inProgress(let label, _):
            return ("Auto-mount of \(label) in progress…", .blue)
        }
    }
}
