import XCTest
@testable import FreeNTFSCore

/// Repository root (gui/Tests/FreeNTFSCoreTests/CoreTests.swift → ../../..).
private let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()

private func plistData(_ object: Any) -> Data {
    try! PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0)
}

final class MountTableTests: XCTestCase {
    func testParsesFuseTAndNativeLines() {
        let text = """
        /dev/disk3s1s1 on / (apfs, sealed, local, read-only, journaled)
        fuse-t:/Disk2 on /Volumes/Disk2 (nfs)
        fuse-t:/My Drive on /Volumes/My Drive (nfs, nodev, nosuid, mounted by someone)
        /dev/disk21s1 on /Volumes/OpenCode (hfs, local, nodev, nosuid, read-only, noowners, quarantine, mounted by me)
        """
        let entries = MountTable.parse(text)
        XCTAssertEqual(entries.count, 4)
        XCTAssertEqual(entries[1], MountEntry(source: "fuse-t:/Disk2", mountPoint: "/Volumes/Disk2", options: ["nfs"]))
        XCTAssertTrue(entries[1].isFuseT)
        XCTAssertEqual(entries[2].mountPoint, "/Volumes/My Drive")
        XCTAssertTrue(entries[2].isFuseT)
        XCTAssertFalse(entries[3].isFuseT)
        XCTAssertTrue(entries[3].options.contains("read-only"))
    }
}

final class VolumeScannerTests: XCTestCase {
    func testCandidatesMatchTheScriptsPartitionTypes() {
        let list: [String: Any] = ["AllDisksAndPartitions": [
            ["DeviceIdentifier": "disk15", "Content": "GUID_partition_scheme", "Partitions": [
                ["DeviceIdentifier": "disk15s1", "Content": "EFI"],
                ["DeviceIdentifier": "disk15s2", "Content": "Microsoft Basic Data"],
            ]],
            ["DeviceIdentifier": "disk20", "Content": "FDisk_partition_scheme", "Partitions": [
                ["DeviceIdentifier": "disk20s1", "Content": "Windows_NTFS"],
            ]],
            // Whole-disk volume, no partition map.
            ["DeviceIdentifier": "disk21", "Content": "Windows_NTFS"],
            ["DeviceIdentifier": "disk22", "Content": "Apple_HFS"],
        ]]
        XCTAssertEqual(VolumeScanner.candidateIdentifiers(fromList: plistData(list)),
                       ["disk15s2", "disk20s1", "disk21"])
    }

    private func info(name: String = "Disk2", fs: String = "NTFS", mountPoint: String = "",
                      writable: Bool = false) -> Data {
        plistData(["DeviceIdentifier": "disk15s2", "FilesystemName": fs, "VolumeName": name,
                   "MountPoint": mountPoint, "WritableVolume": writable, "Size": 2_000_153_477_120,
                   "BusProtocol": "USB", "Internal": false] as [String: Any])
    }

    func testReadWriteWhenFuseTMountedAtVolumesLabel() {
        let mounts = [MountEntry(source: "fuse-t:/Disk2", mountPoint: "/Volumes/Disk2", options: ["nfs"])]
        let v = VolumeScanner.volume(fromInfo: info(), mounts: mounts, ignored: [])
        XCTAssertEqual(v?.state, .readWrite(mountPoint: "/Volumes/Disk2"))
        XCTAssertEqual(v?.deviceNode, "/dev/disk15s2")
        XCTAssertEqual(v?.size, 2_000_153_477_120)
    }

    func testNativeReadOnly() {
        let v = VolumeScanner.volume(fromInfo: info(mountPoint: "/Volumes/Disk2"), mounts: [], ignored: [])
        XCTAssertEqual(v?.state, .readOnlyNative(mountPoint: "/Volumes/Disk2"))
    }

    func testWritableNonFuseTMountIsSomeoneElses() {
        let v = VolumeScanner.volume(fromInfo: info(mountPoint: "/Volumes/Disk2", writable: true), mounts: [], ignored: [])
        XCTAssertEqual(v?.state, .mountedOther(mountPoint: "/Volumes/Disk2"))
    }

    func testNotMounted() {
        XCTAssertEqual(VolumeScanner.volume(fromInfo: info(), mounts: [], ignored: [])?.state, .notMounted)
    }

    func testExFATSharingThePartitionTypeIsSkipped() {
        XCTAssertNil(VolumeScanner.volume(fromInfo: info(fs: "ExFAT"), mounts: [], ignored: []))
    }

    func testEmptyNameFallsBackToDeviceLikeTheScripts() {
        let mounts = [MountEntry(source: "fuse-t:/disk15s2", mountPoint: "/Volumes/disk15s2", options: [])]
        let v = VolumeScanner.volume(fromInfo: info(name: ""), mounts: mounts, ignored: [])
        XCTAssertEqual(v?.label, "disk15s2")
        XCTAssertEqual(v?.state, .readWrite(mountPoint: "/Volumes/disk15s2"))
    }

    func testIgnoreListIsExactLineMatch() {
        let ignored = VolumeScanner.parseIgnoreList("Backup\nDisk2 \n\n")
        XCTAssertEqual(ignored, ["Backup", "Disk2 "])
        XCTAssertFalse(VolumeScanner.volume(fromInfo: info(), mounts: [], ignored: ignored)!.ignoredByAutowatch)
        XCTAssertTrue(VolumeScanner.volume(fromInfo: info(name: "Backup"), mounts: [], ignored: ignored)!.ignoredByAutowatch)
    }
}

final class DaemonTests: XCTestCase {
    // Trimmed real `launchctl print system/local.free-ntfs-mac.autowatch`.
    let running = """
    system/local.free-ntfs-mac.autowatch = {
    \tactive count = 1
    \tpath = /Library/LaunchDaemons/local.free-ntfs-mac.autowatch.plist
    \ttype = LaunchDaemon
    \tstate = running

    \tprogram = /usr/local/bin/ntfs-autowatch
    \targuments = {
    \t\t/usr/local/bin/ntfs-autowatch
    \t}
    \tenvironment = {
    \t\tstate = decoy
    \t}
    \tpid = 56385
    \tlast exit code = (never exited)
    }
    """

    func testRunning() {
        let s = DaemonInspector.parse(printOutput: running, exitStatus: 0, plistInstalled: true)
        XCTAssertTrue(s.isRunning)
        XCTAssertEqual(s.pid, 56385)
        XCTAssertEqual(s.program, "/usr/local/bin/ntfs-autowatch")
        XCTAssertEqual(s.lastExitCode, "(never exited)")
    }

    func testNotLoaded() {
        let s = DaemonInspector.parse(printOutput: "Could not find service", exitStatus: 113, plistInstalled: false)
        XCTAssertFalse(s.loaded)
        XCTAssertFalse(s.isRunning)
    }
}

final class AutowatchLogTests: XCTestCase {
    // Excerpt of a real /var/log/ntfs-autowatch.log: first a Full Disk Access
    // failure, then the 0.2.1 mount-point bug (ntfs-3g "successful", mount
    // failed), then a success after both were fixed.
    let realLog = """
    2026-11-14 18:10:01 ntfs-autowatch avviato (controllo ogni 3s).
    2026-11-14 18:10:08 Disk2 (/dev/disk15s2): già montato in scrittura su /Volumes/Disk2 — nessuna azione.
    2026-11-14 18:11:56 Disk2 (/dev/disk15s2): rilevato, lo monto in scrittura...
      -> Monto /dev/disk15s2 (Disk2) su /Volumes/Disk2 in scrittura...
      Montaggio di Disk2 fallito. Dettagli in /tmp/ntfs-mount.log:
    Error opening '/dev/disk15s2': Operation not permitted
    Failed to mount '/dev/disk15s2': Operation not permitted
    The NTFS partition is in an unsafe state. Please resume and shutdown
    Windows fully (no hibernation or fast restarting), or mount the volume
    read-only with the 'ro' mount option.
    ntfs-3g exit status: 14
    2026-11-14 18:12:03 Disk2: montaggio fallito, non riprovo finché il disco non viene ricollegato. Dettagli in /tmp/ntfs-mount.log
    2026-11-14 18:20:49 Disk2 (/dev/disk15s2): rilevato, lo monto in scrittura...
      -> Monto /dev/disk15s2 (Disk2) su /Volumes/Disk2 in scrittura...
      Montaggio di Disk2 fallito. Dettagli in /tmp/ntfs-mount.log:
    Mounting volume... OK
    Processing of $MFT and $MFTMirr completed successfully.
    Checking the alternate boot sector... OK
    NTFS volume version is 3.1.
    NTFS partition /dev/disk15s2 was processed successfully.
    ntfs-3g exit status: 0
    2026-11-14 18:20:59 Disk2: montaggio fallito, non riprovo finché il disco non viene ricollegato. Dettagli in /tmp/ntfs-mount.log
    2026-11-14 19:32:39 ntfs-autowatch avviato (controllo ogni 3s).
    2026-11-14 19:32:45 Disk2 (/dev/disk15s2): rilevato, lo monto in scrittura...
      -> Monto /dev/disk15s2 (Disk2) su /Volumes/Disk2 in scrittura...
      OK: Disk2 è ora scrivibile su /Volumes/Disk2
    2026-11-14 19:32:51 Disk2: OK, scrivibile su /Volumes/Disk2.
    2026-11-14 19:46:09 Disk2 (/dev/disk15s2): già montato in scrittura su /Volumes/Disk2 — nessuna azione.
    """

    private func lines(_ n: Int) -> String {
        realLog.components(separatedBy: "\n").prefix(n).joined(separator: "\n")
    }

    func testAttemptsAndOutcomes() {
        let s = AutowatchLog.parse(realLog)
        XCTAssertEqual(s.attempts.map(\.outcome), [.failed, .failed, .succeeded])
        XCTAssertNotNil(s.attempts[0].permissionDeniedLine)
        XCTAssertNil(s.attempts[1].permissionDeniedLine)
        XCTAssertEqual(s.attempts[2].device, "/dev/disk15s2")
        XCTAssertEqual(s.attempts[2].label, "Disk2")
        XCTAssertNotNil(s.lastDaemonStart)
    }

    func testEvidenceWorkingAfterSuccess() {
        guard case .working(let label, _) = FullDiskAccessEvidence.assess(AutowatchLog.parse(realLog)) else {
            return XCTFail("expected .working")
        }
        XCTAssertEqual(label, "Disk2")
    }

    func testEvidenceDeniedWhenLastAttemptWasRefused() {
        let s = AutowatchLog.parse(lines(12))
        guard case .denied(_, _, let evidence) = FullDiskAccessEvidence.assess(s) else {
            return XCTFail("expected .denied")
        }
        XCTAssertEqual(evidence, "Error opening '/dev/disk15s2': Operation not permitted")
    }

    func testMountPointBugIsNotBlamedOnPermissions() {
        let s = AutowatchLog.parse(lines(22))
        guard case .failedOtherReason = FullDiskAccessEvidence.assess(s) else {
            return XCTFail("expected .failedOtherReason")
        }
    }

    func testFallsBackToTheFullMountLogOnlyForTheSameAttempt() {
        let s = AutowatchLog.parse(lines(22))
        let attempt = s.latestAttempt!
        let mountLog = "--- … ---\nAttempting to correct errors... Error opening '/dev/disk15s2': Operation not permitted\n"
        guard case .denied = FullDiskAccessEvidence.assess(s, mountLog: mountLog, mountLogModified: attempt.started.addingTimeInterval(3)) else {
            return XCTFail("expected .denied from the matching /tmp/ntfs-mount.log")
        }
        // Written long after (a later manual run): not evidence for this attempt.
        guard case .failedOtherReason = FullDiskAccessEvidence.assess(s, mountLog: mountLog, mountLogModified: attempt.started.addingTimeInterval(3600)) else {
            return XCTFail("a stale mount log must not count")
        }
    }

    func testInProgressAndUntested() {
        guard case .untested = FullDiskAccessEvidence.assess(AutowatchLog.parse(lines(2))) else { return XCTFail() }
        guard case .inProgress = FullDiskAccessEvidence.assess(AutowatchLog.parse(lines(4))) else { return XCTFail() }
    }

    /// The parser keys on the script's own messages; fail loudly if they change.
    func testMarkersStillMatchTheScript() throws {
        let script = try String(contentsOf: repoRoot.appendingPathComponent("bin/ntfs-autowatch"), encoding: .utf8)
        XCTAssertTrue(script.contains(AutowatchLog.attemptMarker))
        XCTAssertTrue(script.contains(AutowatchLog.successMarker))
        XCTAssertTrue(script.contains(AutowatchLog.failureMarker))
        XCTAssertTrue(script.contains(AutowatchLog.startMarker))
        XCTAssertTrue(script.contains("LABEL=\"\(Paths.daemonLabel)\""))
        XCTAssertTrue(script.contains("LOG=\"\(Paths.daemonLog)\""))
        XCTAssertTrue(script.contains(Paths.ignoreFile))
        let mount = try String(contentsOf: repoRoot.appendingPathComponent("bin/ntfs-mount"), encoding: .utf8)
        XCTAssertTrue(mount.contains("LOG=\"\(Paths.mountLog)\""))
    }
}

final class InstallTests: XCTestCase {
    func testRepositoryNtfsMountHasTheFix() throws {
        let script = try String(contentsOf: repoRoot.appendingPathComponent("bin/ntfs-mount"), encoding: .utf8)
        XCTAssertEqual(InstallInspector.hasMountPointFix(script), true)
    }

    func testOldOrderingIsDetected() {
        let old = "mkdir -p \"$mountpoint\"\ndiskutil unmount \"$device\" 2>/dev/null\n"
        XCTAssertEqual(InstallInspector.hasMountPointFix(old), false)
        XCTAssertNil(InstallInspector.hasMountPointFix("#!/bin/bash\necho unrelated\n"))
    }
}

final class CommandTests: XCTestCase {
    func testDeviceValidation() {
        XCTAssertTrue(Commands.isValidDeviceIdentifier("disk15s2"))
        XCTAssertTrue(Commands.isValidDeviceIdentifier("disk4"))
        XCTAssertFalse(Commands.isValidDeviceIdentifier("disk15s2; rm -rf /"))
        XCTAssertFalse(Commands.isValidDeviceIdentifier("/dev/disk15s2"))
        XCTAssertNil(Commands.terminalMountScript(deviceIdentifier: "disk1$(id)"))
        XCTAssertNil(Commands.unmount(mountPoint: "relative"))
        XCTAssertNil(Commands.unmount(mountPoint: "/Volumes/a\nb"))
    }

    /// Shell quoting + AppleScript escaping, end to end through osascript —
    /// the same wrapper the password popup uses, minus the elevation.
    func testQuotingSurvivesOsascriptRoundTrip() {
        let weird = #"Disk "2" it's $HOME `id` \back\slash; done"#
        let outcome = AdminRunner.run("printf '%s' " + Shell.quote(weird), prompt: "unused", admin: false)
        XCTAssertEqual(outcome, .succeeded(output: weird))
    }

    func testUnmountCommandQuotesTheMountPoint() {
        let mp = "/Volumes/It's \"mine\""
        let outcome = AdminRunner.run(
            Commands.unmount(mountPoint: mp)!.replacingOccurrences(of: Shell.quote(Paths.ntfsUnmount), with: "printf '%s'"),
            prompt: "unused", admin: false)
        XCTAssertEqual(outcome, .succeeded(output: mp))
    }

    func testAdminFailureIsReportedNotSwallowed() {
        let outcome = AdminRunner.run("echo boom; exit 3", prompt: "unused", admin: false)
        guard case .failed(_, let message) = outcome else { return XCTFail("expected failure") }
        XCTAssertTrue(message.contains("boom"))
    }

    func testGeneratedCommandFilesAreValidBash() throws {
        for (name, script) in [("mount", Commands.terminalMountScript(deviceIdentifier: "disk15s2")!),
                               ("unmount", Commands.terminalUnmountScript(mountPoint: "/Volumes/Disk2")!),
                               ("install", Commands.terminalInstallScript(cliDirectory: "/Applications/Free NTFS.app/Contents/Resources/cli"))] {
            let url = try Commands.writeCommandFile(named: "test-\(name)", contents: script)
            defer { try? FileManager.default.removeItem(at: url) }
            let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
            XCTAssertEqual(perms, 0o700)
            let check = Shell.run("/bin/bash", ["-n", url.path])
            XCTAssertEqual(check.status, 0, check.stderr)
        }
        XCTAssertTrue(Commands.terminalMountScript(deviceIdentifier: "disk15s2")!
            .contains("'/usr/local/bin/ntfs-mount' '/dev/disk15s2'"))
    }

    /// The admin popup denies ntfs-unmount too (verified live, not just
    /// raw disk opens — see MISTAKE.md), so unmount must go through Terminal
    /// like mount does, not through AdminRunner's popup path.
    func testUnmountGoesThroughTerminalNotThePopup() {
        let script = Commands.terminalUnmountScript(mountPoint: "/Volumes/Disk2")!
        XCTAssertTrue(script.contains("'/usr/local/bin/ntfs-unmount' '/Volumes/Disk2'"))
        XCTAssertNil(Commands.terminalUnmountScript(mountPoint: "relative"))
        XCTAssertNil(Commands.terminalUnmountScript(mountPoint: "/Volumes/a\nb"))
    }

    func testFullDiskAccessURL() {
        XCTAssertEqual(Paths.fullDiskAccessSettingsURL.absoluteString,
                       "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
    }
}
