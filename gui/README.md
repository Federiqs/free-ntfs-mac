# FreeNTFS — menu-bar app

A small native (SwiftUI) menu-bar front end for the free-ntfs-mac
command-line tools. It **doesn't mount anything itself**. It reads the
system's state and hands every real action to the scripts `install.sh`
puts in `/usr/local/bin`: `ntfs-mount`, `ntfs-unmount` and
`ntfs-autowatch`. The mounting logic lives in one place, the scripts, and
the app inherits their fixes.

## Build and run

Needs Xcode (Swift 5.9+), macOS 13 or later.

```bash
gui/build-app.sh                 # -> gui/build/FreeNTFS.app (universal, ad-hoc signed)
open gui/build/FreeNTFS.app      # or copy it to /Applications first
```

The app bundles a copy of `install.sh`, `bin/` and `patches/` from the
checkout it was built from, so its "Run install.sh" button installs exactly
those scripts. It's ad-hoc signed: it runs on the Mac that built it; on
another Mac, Gatekeeper wants a right-click → Open the first time.

Tests (parsing, privilege-path command building, quoting) and two
development modes that don't open any UI or run anything privileged:

```bash
cd gui
swift test --scratch-path /tmp/freentfs-build   # see "Build quirk" below
swift run --scratch-path /tmp/freentfs-build FreeNTFS --status          # what the app sees
swift run --scratch-path /tmp/freentfs-build FreeNTFS --print-commands  # what each button would run
```

**Build quirk:** in a checkout under `~/Desktop`, `swift test` with the
default `.build` folder fails at the ad-hoc signing step ("resource fork,
Finder information, or similar detritus not allowed"), because files there
carry extended attributes. Building outside the checkout (`--scratch-path`)
avoids it. `build-app.sh` already does this.

## What it shows

- **Each connected NTFS volume and its real state:** read-write (ntfs-3g
  via FUSE-T, at `/Volumes/<name>`), read-only (macOS's own mount), not
  mounted, or mounted by some other driver (left alone). Detection is the
  same as the scripts': `diskutil` partition types *Microsoft Basic Data* /
  *Windows_NTFS*, then the NTFS file-system check (to skip exFAT/FAT32),
  and a `fuse-t:` line in `mount` for read-write. It re-checks every 3
  seconds, without privileges.
- **Whether auto-mount (`ntfs-autowatch`) is on:** `launchctl print
  system/local.free-ntfs-mac.autowatch`, which works without root.
- **Full Disk Access, based on evidence only.** No app can read whether
  another binary has Full Disk Access (the TCC database needs Full Disk
  Access itself), so the app never guesses. It reads the service's most
  recent mount attempt in `/var/log/ntfs-autowatch.log`:
  - a success means "working";
  - `Error opening '/dev/diskNsN': Operation not permitted` means "missing",
    and the app shows that exact line;
  - any other failure is reported as "failed, not a permission error in
    the log";
  - no attempt yet means "not verified yet".
- **The two logs** (`/var/log/ntfs-autowatch.log`, `/tmp/ntfs-mount.log`),
  live.
- A warning if the installed `ntfs-mount` predates the 0.2.1 mount-point
  fix.

## What the buttons run, and why that way

Which privilege path each action takes follows from MISTAKE.md. The GUI
admin-password popup (`osascript … with administrator privileges`) gives a
real root process, but macOS still denies it raw disk access. So:

| Action | How | Touches `/dev/diskN`? |
|---|---|---|
| Install | Opens Terminal running the bundled `install.sh`. Not the popup: Homebrew refuses to run as root, and the script asks for `sudo` itself. | No |
| Turn auto-mount on / off | Popup → `ntfs-autowatch --enable` / `--disable` | No |
| **Mount Read-Write** (auto-mount on) | Popup → `launchctl kickstart -k system/local.free-ntfs-mac.autowatch`. The restarted service starts with an empty "already handled" list and, after its 5s settle delay, hands every connected NTFS volume that isn't read-write (and isn't in the ignore list) to `ntfs-mount`. The raw-disk work happens **inside the root daemon**, the path verified on the real drive. The confirmation dialog names any other volume this would also mount. | Only inside the daemon |
| Mount in Terminal | Opens Terminal running `ntfs-mount /dev/diskNsN`, which re-execs itself with a real `sudo`: the documented manual path | Yes, under real `sudo` |
| Unmount | Opens Terminal running `ntfs-unmount /Volumes/<name>` under a real `sudo` — **not** the popup. Verified live: the popup denied this too, every time, with `Operation not permitted`, even though `umount -f` on a FUSE-T NFS mount never touches `/dev/diskN`. The identical command worked immediately from a real sudo Terminal session. See MISTAKE.md. | No raw disk, but the popup is denied it anyway |
| Full Disk Access | Opens System Settings → Privacy & Security → Full Disk Access, and selects `ntfs-3g` and `ntfsfix` in a Finder window to drag in. Also: reveal FUSE-T's real `go-nfsv4` file, copy the paths. | — |

After every action the app re-reads the real state and reports *that*,
never the script's exit code. ntfs-3g itself exits 0 on some failed mounts
(MISTAKE.md). A daemon mount is reported as done only once the volume shows
up as a FUSE-T mount, or as failed with the log lines the service wrote for
that attempt.

## What's tested and what isn't

**Verified:**
- `swift test`: 27 tests. They cover:
  - `mount` / `diskutil` / `launchctl print` parsing;
  - the log parser, against an excerpt of the real daemon log (Full
    Disk Access failure, then the mount-point bug, then success);
  - that the log markers and paths the app relies on still appear in
    `bin/ntfs-autowatch` and `bin/ntfs-mount`;
  - the 0.2.1-fix detector;
  - shell + AppleScript quoting, round-tripped through `osascript` (without
    elevation) with quotes, `$`, backticks and backslashes;
  - `bash -n` on the generated Terminal scripts, including the Terminal-based
    unmount script;
  - that Unmount builds a Terminal script, not an admin-popup command (see
    below for why).
- `--status` against the live system: correctly reported the real 2TB drive
  as read-write at `/Volumes/Disk2`, the daemon running with its real pid,
  7 mount attempts in its log, and "Full Disk Access: working" from the last
  one.
- An unprivileged ntfs-3g mount of a file-backed NTFS image showed up as an
  "other FUSE-T mount" without affecting the real drive's state.
- The Full Disk Access link: on macOS 26.6, System Settings' Privacy &
  Security extension declares `com.apple.preference.security` as its legacy
  id and `Privacy_AllFiles` as the anchor for Full Disk Access. Checked in
  its bundle's plists; we didn't click it.
- The menu, setup and log views, rendered offscreen in several states
  (`FreeNTFS --render-snapshots <dir>`, a development aid).

**Verified live, interactively, by the owner, on the real 2TB drive:**
- Unmount: first found broken — the admin popup failed every time with
  `Operation not permitted`, reproduced twice identically, even though
  `umount -f` on a FUSE-T mount never opens `/dev/diskN`. Fixed to open
  Terminal like Mount does; re-tested and confirmed working end to end
  (banner, and independently with `mount`/`ls /Library/LaunchDaemons`).
- Mount Read-Write (the `launchctl kickstart` path): confirmed the daemon
  mounted the drive and the app reported it correctly.
- Turn Off Auto-mount: confirmed the plist was removed and the already-
  mounted volume was left alone, exactly as designed.
- Turn On Auto-mount: confirmed the daemon came back with a real pid.

Every one of these was checked two ways: the app's own banner, and an
independent command (`mount`, `ls /Library/LaunchDaemons`) run outside the
app. Nothing in this first version is still unverified.

## Not in this first version

- **No mount path behind the password popup**, on purpose: proven not to
  work (MISTAKE.md).
- **No per-volume mount through the daemon.** Restarting the service mounts
  every eligible volume. A per-volume request would need a change to
  `ntfs-autowatch` itself, which is verified on real hardware as it is.
- **No launch-at-login toggle, no localization** (the UI is English; the
  service's own log messages stay in Italian, as the scripts write them), no
  notarized download.
