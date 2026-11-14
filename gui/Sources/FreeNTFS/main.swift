import Foundation
import FreeNTFSCore

// Command-line modes, for checking what the app sees and would run without
// opening any UI or running anything privileged:
//   FreeNTFS --status          read-only snapshot of volumes, daemon, logs
//   FreeNTFS --print-commands  every command/script the buttons would run
let args = CommandLine.arguments.dropFirst()

if args.contains("--status") {
    let cli = Bundle.main.resourceURL?.appendingPathComponent("cli")
    print(SystemSnapshot.capture().report)
    let i = InstallInspector.current(bundledCLI: cli)
    print("Install: cliInstalled=\(i.cliInstalled) fuseT=\(i.fuseT) ntfs3g=\(i.ntfs3gVersion ?? "not runnable") "
          + "missing=\(i.missingTools) mountPointFix=\(i.mountScriptHasMountPointFix.map(String.init) ?? "unknown") "
          + "xcodeCLT=\(i.xcodeCommandLineTools) brew=\(i.homebrewPath ?? "none") "
          + "differFromBundle=\(i.scriptsDifferingFromBundle)")
    print("Go-nfsv4 real file: \(Paths.resolvedGoNFSv4() ?? "not found")")
    exit(0)
}

if args.contains("--print-commands") {
    let snap = SystemSnapshot.capture()
    func admin(_ title: String, _ cmd: String) {
        print("== \(title) (admin password popup)\n\(cmd)\n-- osascript -e:\n\(AdminRunner.appleScript(for: cmd, prompt: "FreeNTFS"))\n")
    }
    admin("Enable auto-mount", Commands.enableAutowatch())
    admin("Disable auto-mount", Commands.disableAutowatch())
    admin("Restart auto-mount service (Mount via service)", Commands.restartAutowatch())
    print("   would mount: \(snap.volumesADaemonRestartWouldMount.map(\.label))\n")
    for v in snap.volumes {
        if let mp = v.state.mountPoint, v.state.isReadWrite, let cmd = Commands.unmount(mountPoint: mp) {
            admin("Unmount \(v.label)", cmd)
        }
        if let script = Commands.terminalMountScript(deviceIdentifier: v.deviceIdentifier) {
            print("== Mount \(v.label) in Terminal (.command file)\n\(script)")
        }
    }
    print("== Install in Terminal (.command file)\n"
          + Commands.terminalInstallScript(cliDirectory: "<FreeNTFS.app>/Contents/Resources/cli"))
    exit(0)
}

if let i = args.firstIndex(of: "--render-snapshots"), args.index(after: i) < args.endIndex {
    let dir = URL(fileURLWithPath: args[args.index(after: i)])
    MainActor.assumeIsolated { SnapshotRenderer.run(outputDirectory: dir) }
    exit(0)
}

FreeNTFSApp.main()
