import Foundation

/// One line of `mount` output.
public struct MountEntry: Equatable, Hashable {
    public let source: String
    public let mountPoint: String
    public let options: [String]

    /// ntfs-3g served through FUSE-T shows up as `fuse-t:/<label> on … (nfs…)`.
    /// This is the same test bin/ntfs-mount and bin/ntfs-unmount use
    /// (`^fuse-t:`), so the app and the scripts agree on what "ours" means.
    public var isFuseT: Bool { source.hasPrefix("fuse-t:") }

    public init(source: String, mountPoint: String, options: [String]) {
        self.source = source
        self.mountPoint = mountPoint
        self.options = options
    }
}

public enum MountTable {
    // "<source> on <mount point> (<opt>, <opt>, …)"
    private static let line = try! NSRegularExpression(pattern: #"^(.+?) on (/.*) \(([^()]*)\)$"#)

    public static func parse(_ text: String) -> [MountEntry] {
        text.split(separator: "\n").compactMap { raw in
            let s = String(raw)
            let ns = s as NSString
            guard let m = line.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
            let opts = ns.substring(with: m.range(at: 3))
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
            return MountEntry(source: ns.substring(with: m.range(at: 1)),
                              mountPoint: ns.substring(with: m.range(at: 2)),
                              options: opts)
        }
    }

    public static func current() -> [MountEntry] {
        parse(Shell.run("/sbin/mount").stdout)
    }
}

public enum VolumeState: Equatable {
    case notMounted
    /// macOS's own (FSKit) mount, read-only — what you get right after plug-in.
    case readOnlyNative(mountPoint: String)
    /// ntfs-3g via FUSE-T at /Volumes/<label>: what ntfs-mount produces.
    case readWrite(mountPoint: String)
    /// Mounted by something that is neither macOS's read-only driver nor us
    /// (e.g. another NTFS driver). Reported, never touched.
    case mountedOther(mountPoint: String)

    public var mountPoint: String? {
        switch self {
        case .notMounted: return nil
        case .readOnlyNative(let mp), .readWrite(let mp), .mountedOther(let mp): return mp
        }
    }

    public var isReadWrite: Bool {
        if case .readWrite = self { return true }
        return false
    }
}

public struct NTFSVolume: Identifiable, Equatable {
    public var id: String { deviceIdentifier }
    public let deviceIdentifier: String       // disk15s2
    public let volumeName: String             // may be empty
    public let size: Int64
    public let busProtocol: String?
    public let isInternal: Bool
    public var state: VolumeState
    /// Listed in /usr/local/etc/ntfs-autowatch.ignore: the daemon never touches it.
    public var ignoredByAutowatch: Bool

    public init(deviceIdentifier: String, volumeName: String, size: Int64, busProtocol: String?,
                isInternal: Bool, state: VolumeState, ignoredByAutowatch: Bool) {
        self.deviceIdentifier = deviceIdentifier
        self.volumeName = volumeName
        self.size = size
        self.busProtocol = busProtocol
        self.isInternal = isInternal
        self.state = state
        self.ignoredByAutowatch = ignoredByAutowatch
    }

    public var deviceNode: String { "/dev/" + deviceIdentifier }
    /// Same fallback as the scripts: no volume name → use the device node name.
    public var label: String { volumeName.isEmpty ? deviceIdentifier : volumeName }
    /// Where ntfs-mount mounts it (`/Volumes/$label`).
    public var expectedMountPoint: String { "/Volumes/" + label }
}

public enum VolumeScanner {
    /// The partition types bin/ntfs-mount and bin/ntfs-autowatch scan for
    /// (`awk '/Microsoft Basic Data|Windows_NTFS/'`). "Microsoft Basic Data"
    /// is shared with exFAT/FAT32, hence the per-device NTFS check below.
    static let candidateContents: Set<String> = ["Microsoft Basic Data", "Windows_NTFS"]

    static func plist(_ data: Data) -> [String: Any]? {
        (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    /// Device identifiers from `diskutil list -plist` whose partition type
    /// could hold NTFS.
    public static func candidateIdentifiers(fromList data: Data) -> [String] {
        guard let root = plist(data),
              let disks = root["AllDisksAndPartitions"] as? [[String: Any]] else { return [] }
        var ids: [String] = []
        for disk in disks {
            if let content = disk["Content"] as? String, candidateContents.contains(content),
               let id = disk["DeviceIdentifier"] as? String {
                ids.append(id)
            }
            for part in disk["Partitions"] as? [[String: Any]] ?? [] {
                if let content = part["Content"] as? String, candidateContents.contains(content),
                   let id = part["DeviceIdentifier"] as? String {
                    ids.append(id)
                }
            }
        }
        return ids
    }

    /// Builds a volume from `diskutil info -plist <id>`, or nil if it isn't
    /// NTFS. `FilesystemName` is the plist form of the "File System
    /// Personality" field the scripts check.
    public static func volume(fromInfo data: Data, mounts: [MountEntry], ignored: Set<String>) -> NTFSVolume? {
        guard let info = plist(data),
              (info["FilesystemName"] as? String) == "NTFS",
              let id = info["DeviceIdentifier"] as? String else { return nil }

        var volume = NTFSVolume(
            deviceIdentifier: id,
            volumeName: info["VolumeName"] as? String ?? "",
            size: (info["Size"] as? NSNumber)?.int64Value ?? 0,
            busProtocol: info["BusProtocol"] as? String,
            isInternal: info["Internal"] as? Bool ?? false,
            state: .notMounted,
            ignoredByAutowatch: false)
        volume.ignoredByAutowatch = ignored.contains(volume.label)

        let nativeMountPoint = info["MountPoint"] as? String ?? ""
        if mounts.contains(where: { $0.isFuseT && $0.mountPoint == volume.expectedMountPoint }) {
            volume.state = .readWrite(mountPoint: volume.expectedMountPoint)
        } else if !nativeMountPoint.isEmpty {
            let writable = info["WritableVolume"] as? Bool ?? false
            volume.state = writable ? .mountedOther(mountPoint: nativeMountPoint)
                                    : .readOnlyNative(mountPoint: nativeMountPoint)
        }
        return volume
    }

    /// Exact-line matches, like the daemon's `grep -qxF "$label"`.
    public static func parseIgnoreList(_ text: String) -> Set<String> {
        Set(text.components(separatedBy: "\n").filter { !$0.isEmpty })
    }

    public struct Result: Equatable {
        public var volumes: [NTFSVolume]
        /// FUSE-T mounts not at the /Volumes/<label> of any connected NTFS
        /// volume (e.g. a drive pulled while mounted, or an image mount).
        public var otherFuseTMounts: [MountEntry]
    }

    /// Read-only: diskutil + mount, no privileges needed. Blocking.
    public static func scan() -> Result {
        let mounts = MountTable.current()
        let ignored = (try? String(contentsOfFile: Paths.ignoreFile, encoding: .utf8))
            .map(parseIgnoreList) ?? []
        let list = Shell.run("/usr/sbin/diskutil", ["list", "-plist"])
        var volumes: [NTFSVolume] = []
        for id in candidateIdentifiers(fromList: Data(list.stdout.utf8)) {
            let info = Shell.run("/usr/sbin/diskutil", ["info", "-plist", id])
            if let v = volume(fromInfo: Data(info.stdout.utf8), mounts: mounts, ignored: ignored) {
                volumes.append(v)
            }
        }
        let claimed = Set(volumes.map(\.expectedMountPoint))
        let others = mounts.filter { $0.isFuseT && !claimed.contains($0.mountPoint) }
        return Result(volumes: volumes, otherFuseTMounts: others)
    }
}
