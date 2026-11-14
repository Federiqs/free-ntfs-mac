// swift-tools-version:5.9
//
// FreeNTFS — a menu-bar front end for the free-ntfs-mac command-line tools.
// It never mounts anything itself: it reads system state (diskutil, mount,
// launchctl, the daemon's log) and hands every real action to the existing
// scripts in /usr/local/bin. See gui/README.md.

import PackageDescription

let package = Package(
    name: "FreeNTFS",
    platforms: [.macOS(.v13)],
    targets: [
        // Everything that can be tested without a UI: parsing diskutil /
        // mount / launchctl / log output, and building the exact commands the
        // app runs.
        .target(name: "FreeNTFSCore"),
        .executableTarget(name: "FreeNTFS", dependencies: ["FreeNTFSCore"]),
        .testTarget(name: "FreeNTFSCoreTests", dependencies: ["FreeNTFSCore"]),
    ],
    swiftLanguageVersions: [.v5]
)
