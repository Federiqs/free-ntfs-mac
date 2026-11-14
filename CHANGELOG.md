# Changelog

## Unreleased — FreeNTFS menu-bar app (`gui/`)

- New SwiftUI menu-bar app, a front end for the existing scripts with no
  mount logic of its own. It shows:
  - each connected NTFS volume as read-write (ours), read-only (macOS),
    not mounted, or mounted by another driver;
  - the `ntfs-autowatch` service state;
  - Full Disk Access status, inferred only from the service's last mount
    attempt in its log (there's no way to query it directly).

  It also has a three-step setup window and a live log viewer. Build with
  `gui/build-app.sh`. Details: [gui/README.md](gui/README.md).
- Privilege paths follow MISTAKE.md:
  - Raw-disk work only ever runs inside the root daemon ("Mount" restarts
    it with `launchctl kickstart -k`) or under a real `sudo` in Terminal
    ("In Terminal…").
  - The admin-password popup is used only for enable/disable, the restart
    and `ntfs-unmount`.
  - `install.sh` runs in Terminal, because Homebrew refuses to run as root.
- Verified:
  - 26 unit tests, including the log parser against the real daemon log
    and quoting round-tripped through `osascript`;
  - `--status` against the live system (real drive, real daemon);
  - the Full Disk Access deep link's anchor (`Privacy_AllFiles`) in macOS
    26.6's System Settings bundle;
  - the views rendered offscreen.
- **Not yet verified:** any action behind the password prompt, and the
  Terminal buttons, on a real setup.

## 0.2.1 — fix: mount failed whenever macOS's read-only mount was present

- `bin/ntfs-mount`: create the `/Volumes/<name>` mount point *after*
  unmounting macOS's own read-only mount (and after the settle delay), not
  before. macOS deletes that folder together with its mount, so FUSE-T's
  NFS mount step had nothing to mount onto: FUSE-T logged
  `mount ... exit status 66`, ntfs-3g unmounted itself ~100ms after
  "Mounted (Read-Write)" and still exited 0. Also unmount with
  `diskutil unmount` first (it removes the folder before returning) and
  `umount -f` second, as a fallback.
  - This is what broke every live `ntfs-autowatch` mount, but it was not
    daemon-specific: a manual `ntfs-mount` run right after plug-in hit it
    too (re-running worked, since the native mount was gone by then).
  - Verified without root or the real drive, using an NTFS image attached
    with `hdiutil` so macOS mounts it natively first, and `ntfs-mount`
    pointed at the image file: the 0.2.0 sequence failed 3/3 with the exact
    log signature seen live; the new one mounted read-write 3/3, 3/3 with
    `diskutil unmount` forced to fail (the `umount -f` fallback), and once
    run from a background launchd job.
  - **Verified on the real drive**, as root, from the LaunchDaemon: starting
    from macOS's native read-only mount (the exact condition that triggered
    the bug), `ntfs-autowatch`'s root daemon mounted it read-write
    unattended within 6s, confirmed with a real write (`touch`/`rm` through
    the mount). Full Disk Access was granted on `ntfs-3g`, `ntfsfix` and
    `go-nfsv4` for this run — not re-tested with `go-nfsv4` left out, so
    whether that third grant is actually required is still unconfirmed.
- `bin/ntfs-autowatch`: `--enable` now says that `ntfs-3g` and `ntfsfix`
  need Full Disk Access (found live: without it the daemon can't open the
  disk, "Operation not permitted"); the failure log line also points to
  FUSE-T's own log, the only place the NFS-step error shows up.
- `MISTAKE.md`: the mount-point bug, how to read FUSE-T's bare exit codes,
  the Full Disk Access requirement, and the "LaunchDaemon has no session"
  theory that turned out wrong (the image mount worked from both the GUI
  and the background launchd domains).

## 0.2.0 — opt-in auto-mount, real performance numbers

- `bin/ntfs-autowatch` (new): opt-in auto-mount on plug-in.
  `ntfs-autowatch --enable` installs a root LaunchDaemon that polls
  `diskutil list` every 3s and, 5s after an NTFS volume appears, hands it
  to `ntfs-mount` (same dirty-flag clearing, settle delay and success
  polling as a manual mount — no logic duplicated). Each volume is handled
  once per attach, so `ntfs-unmount` or a deliberate read-only mount isn't
  undone behind your back; volume names in
  `/usr/local/etc/ntfs-autowatch.ignore` are never touched; failures aren't
  retried until the drive is replugged. `--disable` removes it and leaves
  live mounts alone (`AbandonProcessGroup`). `--dry-run [--once]` shows
  decisions without root.
  - Verified: syntax; `plutil -lint` on the generated plist; the scan/state
    logic against mocked `diskutil`/`mount`/`ntfs-mount` (settle delay,
    once-per-attach, unplug/replug, exFAT partitions skipped, success,
    no-retry on failure, no re-mount after a manual unmount, ignore list);
    `--dry-run` against the real attached 2TB drive; the same generated
    plist loaded into the *user* launchd domain in dry-run mode, where it
    ran and detected the drive correctly.
  - **Not yet verified** (needs a real root terminal and a physical
    replug): `--enable`/`--disable` themselves, an actual mount performed
    by the root LaunchDaemon (including whether macOS grants it raw disk
    access), the timing against macOS's own read-only mount on plug-in,
    and behavior for a drive attached at boot before login.
- `install.sh`: also installs `ntfs-autowatch`, but does **not** enable
  it — just prints how to opt in. Auto-mount changes what plugging in a
  drive does, so it stays an explicit choice.
- `tools/ntfs-bench` (new): sequential read/write + small-file benchmark
  for any mounted volume, no root needed. Bypasses the page cache
  (`F_NOCACHE`) and includes `fsync` in write timings.
- First real performance numbers (README "Performance"), replacing the
  old unmeasured "~18-20MB/s" line: 20.7-21.5MB/s write, 21.4-23.0MB/s
  read (5 x 1GB runs), 31-33 small files/s created on the 2TB WD Elements drive — attached
  through a USB 2.0 hub, so the link was 480Mb/s. Against an NTFS image on
  the internal SSD (the ntfs-3g + FUSE-T ceiling): 530-660MB/s write,
  1-1.4GB/s read, but still only ~85 small files/s.
- Mount options A/B-tested on that SSD image (Disk2 couldn't be remounted
  from a non-interactive shell). Default `MOUNT_OPTS` left unchanged;
  findings recorded as a comment in `bin/ntfs-mount` and in the README:
  `rwsize=262144` roughly doubled the sequential ceiling; `rwsize=1048576`
  made writes 30-50x slower; `noappledouble` doubled small-file creation but
  breaks extended attributes; `noatime` and `big_writes` made no
  difference; `backend=smb` and `namedattr` didn't work.
- `MISTAKE.md`: launchd can't run a script from `~/Desktop`; small
  benchmark files measure the cache, not the disk; `rwsize=1048576`'s write
  collapse; `backend=smb` being broken with ntfs-3g.

## 0.1.1 — mount reliability fix

- `bin/ntfs-mount`: fixed a false "mount failed" report after moving the
  repo to a new machine and testing against a real external drive. Two
  races were at play — mounting immediately after `diskutil unmount`
  returns, and checking for mount success only once (1 second in) when
  FUSE-T's first mount of a session can take a few seconds to spin up its
  NFS loopback server. Added a settle delay before mounting and polling
  for up to 5 seconds (instead of a single check) before reporting
  failure. The underlying mount was actually working the whole time —
  running the same `ntfs-3g` command by hand confirmed it.
- `MISTAKE.md`: documented the above race, plus the fact that a `sudo`
  password prompt from `ntfs-mount`/`ntfs-unmount` cannot be satisfied from
  a non-interactive shell (CI, an agent-run command, etc.) — run them from
  a real terminal.
- Re-validated end-to-end on a real 2TB external NTFS drive: write, move
  between folders, and read-back all confirmed working after the fix.

## 0.1.0 — initial release

- `install.sh`: one-command installer — Homebrew dependencies, FUSE-T cask,
  clone + patch + build + install of ntfs-3g (macos-fuse-t fork) into
  `/usr/local`.
- `patches/0001-fix-macos-install-hook.patch`: fixes upstream's Linux-only
  `install-exec-hook` that otherwise breaks `make install` on macOS.
- Installer overrides `rootbindir`/`rootsbindir` (upstream default of
  `/bin` is SIP-protected on modern macOS) and adds
  `-headerpad_max_install_names` plus explicit `-rpath` entries for both
  the install prefix and FUSE-T's library location, so the installed
  binaries run standalone with no manual `install_name_tool` step.
- `bin/ntfs-mount`: scans connected disks for NTFS volumes, auto-clears the
  Windows dirty-shutdown flag (`ntfsfix --clear-dirty`) before mounting,
  self-elevates via `sudo` (a GUI `osascript` password popup was tried
  first and rejected — confirmed via direct testing that macOS denies raw
  disk access to processes elevated that way even though they run as
  genuine root, likely a TCC/Full Disk Access restriction specific to that
  elevation path).
- `bin/ntfs-unmount`: matching safe-unmount command, same self-elevation.
- Validated with: a synthetic 200MB NTFS image (write/rename/delete,
  persistence verified across a full unmount/remount cycle, structural
  integrity checked with `ntfsinfo`); a real external 2TB NTFS drive
  (mount/unmount cycles, real-world deletions); a 600MB / 507-file stress
  test with nested directories and mixed file sizes (SHA-256 checksums of
  every file identical before and after a full unmount/remount cycle);
  `install.sh` run end-to-end, unmodified, against an isolated test
  prefix.
- Known limitation documented: `rmdir` can refuse to remove a directory
  that previously held very large numbers of files, even when genuinely
  empty — an ntfs-3g limitation around uncompacted NTFS directory indexes,
  not something this project can fix; `chkdsk` from Windows resolves it.
- `MISTAKE.md`: every dead end hit while building this, documented so
  they don't need to be rediscovered — build system quirks (dropped rpath
  flags, upstream's Linux-only install hook, `/bin` being SIP-protected),
  macOS permission surprises (GUI `osascript` elevation not granting raw
  disk access despite running as genuine root, confirmed with `id`),
  and NTFS-specific behavior (the directory-index limitation, the Windows
  dirty-flag check, disk identifiers shifting across reconnects).
- `.gitignore` added.
- Local development leftovers cleaned up: the macFUSE cask (unused — this
  project only ever uses FUSE-T) and ~800MB of build/test artifacts from
  earlier exploration removed from the development machine.
