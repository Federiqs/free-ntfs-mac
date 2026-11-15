# free-ntfs-mac

Free, open-source read-write NTFS support for macOS — no kernel extension,
no Reduced Security mode, no SIP changes, no paid driver (Paragon, Tuxera
NTFS for Mac, etc.).

macOS can **read** NTFS drives out of the box, but mounts them **read-only**
by default (via Apple's own FSKit NTFS implementation). This project gives
you real read-write access using [ntfs-3g](https://github.com/tuxera/ntfs-3g)
(the de-facto standard open-source NTFS driver) linked against
[FUSE-T](https://www.fuse-t.org) instead of macFUSE — which means it works
entirely in userspace, with no kernel extension to approve and no need to
lower your Mac's security settings.

## Why this exists

The usual free option (macFUSE + ntfs-3g) still ships a kernel extension on
Apple Silicon, which means booting into Recovery Mode and lowering System
Integrity Protection just to approve it. FUSE-T avoids that entirely by
implementing FUSE through a userspace NFS loopback server. This repo wires
ntfs-3g up to build against FUSE-T instead, with the install-path patches
and helper scripts needed to make it actually usable day to day.

## What you get

- `install.sh` — one command, installs everything (FUSE-T + a patched,
  properly-linked build of ntfs-3g) into `/usr/local`.
- `ntfs-mount` — detects connected NTFS volumes and mounts them read-write.
  Clears the Windows "unsafe shutdown" dirty flag automatically (very
  common after an improper eject, hibernation, or power loss on Windows —
  ntfs-3g otherwise refuses to mount read-write when it's set).
- `ntfs-unmount` — the matching safe-unmount command.
- `ntfs-autowatch` — optional, opt-in auto-mount: a small LaunchDaemon
  that mounts NTFS drives read-write as soon as you plug them in, no
  terminal, no password prompt. Off unless you enable it.
- `tools/ntfs-bench` — measures real read/write throughput on a mounted
  volume, so you can check your own drive instead of trusting ours.
- `gui/` — **FreeNTFS**, an optional menu-bar app on top of the scripts
  above (new, partly verified, see [gui/README.md](gui/README.md)). It
  shows each NTFS volume's real state, whether auto-mount is on, and
  whether Full Disk Access is working, based on the service's last mount
  attempt. It walks you through setup, including the one manual Full Disk
  Access step. Mount, unmount and enable go through the same scripts; it
  has no mount logic of its own.

## Requirements

- macOS on Apple Silicon or Intel (tested on macOS 26 "Tahoe")
- [Xcode Command Line Tools](https://developer.apple.com/xcode/) (`xcode-select --install`)
- [Homebrew](https://brew.sh)

## Install

```bash
git clone https://github.com/<your-username>/free-ntfs-mac.git
cd free-ntfs-mac
./install.sh
```

You'll be asked for your password once. The script installs build
dependencies and FUSE-T via Homebrew, then builds and installs ntfs-3g into
`/usr/local/bin`.

## Usage

Plug in an NTFS drive (macOS will auto-mount it read-only, as usual), then:

```bash
ntfs-mount
```

It scans for NTFS volumes, shows you what it found, and asks before
mounting each one read-write (or pass `-y` to mount everything without
asking). You'll get one password prompt — `ntfs-mount` re-executes itself
with `sudo` so you don't have to remember to type it yourself.

To mount one specific device directly:

```bash
ntfs-mount /dev/disk3s2
```

When you're done:

```bash
ntfs-unmount /Volumes/YourDriveName
# or
ntfs-unmount -a      # unmount every NTFS volume currently mounted read-write
```

### Auto-mount on plug-in (opt-in)

```bash
ntfs-autowatch --enable      # one password prompt, then never again
ntfs-autowatch --disable     # stop it; anything already mounted stays mounted
```

`--enable` installs a LaunchDaemon (`/Library/LaunchDaemons/local.free-ntfs-mac.autowatch.plist`)
that runs as root, starts at boot, and checks `diskutil list` every 3
seconds. When an NTFS volume appears, it waits 5 seconds for macOS to finish
its own read-only mount, then hands the device to `ntfs-mount` — the same
dirty-flag clearing, settle delay and success polling you get by hand.
Log: `/var/log/ntfs-autowatch.log`.

**One-time permission:** a background service doesn't inherit Terminal's
disk access. Add `/usr/local/bin/ntfs-3g` and `/usr/local/bin/ntfsfix` under
System Settings → Privacy & Security → Full Disk Access (drag them in from
Finder, Go → Go to Folder…). Without that, every mount fails with
`Operation not permitted` in `/tmp/ntfs-mount.log`. The verified working
setup also had FUSE-T's `go-nfsv4` added (its real file, not the
`/usr/local/bin/go-nfsv4` symlink: `/Library/Application Support/fuse-t/bin/go-nfsv4-1.2.9`)
— add that one too if the first two aren't enough; see MISTAKE.md.

It's opt-in, not turned on by `install.sh`, because it changes what
plugging in a drive does: every NTFS volume becomes writable without
asking. To stay out of your way:

- **Each volume is handled once per plug-in.** If you `ntfs-unmount` it,
  or mount it read-only yourself (`diskutil mount <device>`), it stays that
  way until you unplug and replug the drive.
- **Volumes you never want touched** go in `/usr/local/etc/ntfs-autowatch.ignore`,
  one volume name per line (create the file with `sudo`).
- **A failed mount is not retried** until the drive is reconnected — run
  `ntfs-mount` by hand and check `/tmp/ntfs-mount.log`.

`ntfs-autowatch --dry-run --once` (no root needed) shows what it would do
with the drives connected right now, without mounting anything; drop
`--once` to keep watching and see what it does when you plug a drive in.

**Status:** verified end-to-end on a real drive. Starting from macOS's own
read-only mount (what you get right after plugging a drive in), the root
LaunchDaemon mounted it read-write unattended within 6 seconds, confirmed
with a real write through the mount — see [CHANGELOG.md](CHANGELOG.md) for
the 0.2.1 fix that got it there (a mount-point bug in `ntfs-mount`, not a
LaunchDaemon limitation).

## How it works

- `ntfs-3g`/`lowntfs-3g` are built from the
  [macos-fuse-t/ntfs-3g](https://github.com/macos-fuse-t/ntfs-3g) fork of
  Tuxera's ntfs-3g, configured with `--with-fuse=external` and linked
  against FUSE-T's `libfuse-t.dylib` instead of macFUSE's `libfuse.dylib`.
- [patches/0001-fix-macos-install-hook.patch](patches/0001-fix-macos-install-hook.patch)
  fixes a Linux-specific install hook in upstream's build system (it tries
  to move `.so` files between `/lib` and `/usr/local/lib`, a distinction
  that doesn't exist on macOS and breaks `make install` outright).
- `install.sh` also overrides `rootbindir`/`rootsbindir` (upstream defaults
  to `/bin`, which is SIP-protected and unwritable even by root on modern
  macOS) and adds the missing `-headerpad_max_install_names` / `-rpath`
  linker flags so the installed binaries can actually find their libraries
  at runtime without extra manual steps.

## Performance

Measured with [`tools/ntfs-bench`](tools/ntfs-bench) (1GB sequential file,
page cache bypassed, `fsync` included; 500 x 32KB files) on a MacBook Air
M4, macOS 26.6, FUSE-T 1.2.9, default mount options:

| Setup | Write | Read | 32KB files created |
|---|---|---|---|
| WD Elements 2TB, via a USB 2.0 hub (480Mb/s link), 5 runs | 20.7-21.5MB/s | 21.4-23.0MB/s | 31-33/s |
| NTFS image on the internal SSD — the ntfs-3g + FUSE-T ceiling, no USB involved | 530-660MB/s | 1.05-1.4GB/s | 81-86/s |

- **On that drive, the USB link is the bottleneck**, not ntfs-3g or
  FUSE-T — the software path is ~25x faster. No mount option can fix that;
  a direct (hub-free) USB 3 connection can. We haven't measured a USB 3
  drive yet; run `tools/ntfs-bench /Volumes/YourDrive` and you'll know.
- **Small files are slow everywhere.** Every file is a round trip through
  FUSE-T's NFS loopback into ntfs-3g, and macOS adds a `._` companion file
  for nearly every one. Copying a photo library will be far slower than
  copying a few large videos of the same total size.

Mount options we A/B-tested — on the SSD image only, since remounting the
real drive needs a root terminal. Each was mounted fresh and run at least
twice:

| Added to `-o` | Result |
|---|---|
| `rwsize=262144` | ~2x the ceiling: 1.1-1.35GB/s write, 2.2-2.6GB/s read (5 runs). Only matters for fast drives — not the default until tested on one. |
| `rwsize=524288` | Erratic: 1.26GB/s write in one session, 0.43GB/s in the next. |
| `rwsize=1048576` | **Writes 30-50x slower** (11-22MB/s, 4 runs in 2 sessions). Don't. |
| `noappledouble` | No `._` files, small-file creation ~2x (165/s), deletes ~1.5x. But extended attributes can't be stored at all, and `cp` of a file that has any exits with an error (the data is still copied intact). Not the default. |
| `noatime`, `big_writes` | No measurable difference. |
| `namedattr` | Doesn't give real xattr support — writes fail with "Attribute not found". |
| `backend=smb` | Broken with ntfs-3g: file creation fails with I/O errors. |

`bin/ntfs-mount` keeps the default and lists the two promising options in
a comment next to `MOUNT_OPTS`, so you can try them on your own drive.

## Known limitations

- **`sudo` is required to mount a real block device** (`/dev/diskNsN`).
  This isn't a FUSE-T or macFUSE limitation — it's a hard-coded safety
  check in ntfs-3g's own source (`getuid() && ctx->blkdev`), present
  regardless of which FUSE backend you use. `ntfs-mount` re-execs itself
  with `sudo` so you only need to confirm once per terminal session.
- **A GUI password popup (`osascript ... with administrator privileges`)
  does *not* work for this** — even though the resulting process is
  genuinely root (confirmed with `id`), macOS denies it raw disk access
  (a TCC/Full Disk Access restriction that only applies to processes
  elevated that way, not to a normal `sudo` session in Terminal). That's
  why `ntfs-mount` uses a real `sudo` re-exec instead of a popup.
- **Directories that previously held very large numbers of files can
  sometimes resist `rmdir`** with a "Directory not empty" error even when
  genuinely empty (confirmed via `ls -la` and `stat`). This is a known
  ntfs-3g limitation: a heavily-fragmented NTFS directory index isn't
  automatically compacted, and ntfs-3g conservatively refuses to remove it.
  The fix is a `chkdsk` pass from Windows, or simply leaving the empty
  folder behind if you're about to reformat the volume anyway.
- **Large-file throughput is bound by your drive and USB link, not by
  this stack** — ~21-23MB/s read and write on our USB 2.0-linked test
  drive, against a 530-660MB/s write / 1-1.4GB/s read ceiling for
  ntfs-3g + FUSE-T itself. **Small files are the real weak spot**: ~31-33
  files/s created on that drive, and only ~85/s even with an SSD
  underneath. Numbers and what we tried in [Performance](#performance).
- **macOS writes a hidden `._` file next to almost every file you create**
  (that's how it stores extended attributes, e.g. `com.apple.provenance`,
  on FUSE-T's NFS-based mounts). Windows shows them. They're harmless;
  deleting them only loses Mac-only metadata such as Finder tags.
- **`ntfs-mount`/`ntfs-unmount` need a real interactive terminal.** Since
  they self-elevate with `sudo`, running them from a non-interactive shell
  (a CI job, an IDE "run" panel, a script with no pty) fails with "a
  terminal is required to read the password". Run them from an actual
  Terminal window — or enable `ntfs-autowatch` once from one, after which
  mounting needs no terminal at all.

## Contributing / debugging

If something in the build or the mount flow isn't working, check
[MISTAKE.md](MISTAKE.md) first — it documents every dead end we hit while
building this (build system quirks, macOS permission surprises, NTFS
behavior) so you don't have to rediscover them.

## Uninstall

```bash
ntfs-autowatch --disable     # only if you enabled auto-mount
sudo rm -f /usr/local/bin/{ntfs-3g,ntfs-3g.probe,lowntfs-3g,mkntfs,ntfsfix,ntfsinfo,ntfscluster,ntfsls,ntfscat,ntfscmp,ntfslabel,ntfsundelete,ntfsresize,ntfsclone,ntfscp,ntfs-mount,ntfs-unmount,ntfs-autowatch}
sudo rm -f /usr/local/etc/ntfs-autowatch.ignore /var/log/ntfs-autowatch.log
sudo rm -f /usr/local/lib/libntfs-3g*
brew uninstall --cask fuse-t
```

## Credits & license

- [ntfs-3g](https://github.com/tuxera/ntfs-3g) — © Tuxera, Szabolcs
  Szakacsits, Erik Larsson and contributors, licensed GPLv2. This is the
  actual NTFS driver doing all the real work; this repo just wires it up
  to build and run cleanly on macOS with FUSE-T.
- [macos-fuse-t/ntfs-3g](https://github.com/macos-fuse-t/ntfs-3g) — the
  macOS/FUSE-T-targeted fork this repo builds against.
- [FUSE-T](https://www.fuse-t.org) — the kext-less FUSE implementation
  that makes this possible without touching SIP.

This repository (the install script, the mount/unmount helpers, and the
install-path patch) is licensed under the GPLv2, matching ntfs-3g — see
[LICENSE](LICENSE).
