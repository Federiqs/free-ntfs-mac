# Mistakes & lessons learned

Things that didn't work, looked like they should have, and cost real time
to debug while building this project. Read this before "fixing" something
that's already been tried and found broken.

## Build

- **`brew install ntfs-3g` (Homebrew core formula) does not work on
  macOS.** It hard-requires Linux and refuses outright
  ("`ntfs-3g: Linux is required for this software`"). You need either
  `gromgit/fuse/ntfs-3g-mac` (links against macFUSE) or, for the FUSE-T
  approach this project uses, a manual build of
  [macos-fuse-t/ntfs-3g](https://github.com/macos-fuse-t/ntfs-3g).

- **`FUSE_LIBS="... -Wl,-rpath,/usr/local/lib -lfuse-t"` passed to
  `./configure` does not survive into the final link command.** We
  verified this by inspecting the actual `gcc ... -o ntfs-3g ...` line in
  the `make` log — it only contained `-lfuse-t`, no rpath flag at all,
  even though `FUSE_LIBS` was set correctly at configure time. Something
  in ntfs-3g's Makefile machinery drops it. Don't waste time chasing this
  in the build system — apply `install_name_tool -add_rpath` on the
  installed binaries instead, which is 100% reliable.

- **`install_name_tool -add_rpath` can fail** with "larger updated load
  commands do not fit" if the binary wasn't linked with enough header
  padding and the new rpath string is long (e.g. a long install prefix
  path). Fix it at link time with `-Wl,-headerpad_max_install_names` in
  `LDFLAGS`, not after the fact — this is what let us catch it, since it
  only showed up when testing against a long scratch-directory `PREFIX`,
  not against the short `/usr/local`.

- **One `-rpath` entry is not enough if your `PREFIX` differs from
  `/usr/local`.** FUSE-T always installs `libfuse-t.dylib` in
  `/usr/local/lib` via its own Homebrew cask, regardless of what
  `--prefix` you give ntfs-3g's `configure`. You need a separate rpath
  entry for wherever FUSE-T actually put its library, in addition to your
  own install prefix. This only becomes visible when you test with a
  `PREFIX` other than `/usr/local` — testing only against the default
  prefix would have hidden the bug.

- **Upstream's `install-exec-hook` in `libntfs-3g/Makefile.am` breaks
  `make install` outright on macOS.** It unconditionally tries to `mv`
  `libntfs-3g.so*` from `libdir` to `rootlibdir` — a Linux FHS distinction
  (`/lib` vs `/usr/local/lib`) that doesn't exist on macOS, where we
  produce `.dylib` files, not `.so`. The `mv` fails because nothing
  matches the glob, and `make install` aborts. See
  `patches/0001-fix-macos-install-hook.patch`.

- **Upstream's `rootbindir` defaults to `/bin`.** On modern macOS, `/bin`
  is SIP-protected and unwritable even by root — `make install` fails
  with "sandbox detected... Operation not permitted". Override it:
  `make install rootbindir=/usr/local/bin rootsbindir=/usr/local/bin`.

- **Running `autoreconf`/build tools directly inside a freshly
  `git clone`d external repository can get blocked by an automation
  safety classifier** ("execution of unreviewed external code"), even
  when run from a trusted script. Budget for a human to run the build
  step themselves if you're scripting this pipeline from an agent.

## Mounting

- **ntfs-3g always refuses to mount a real block device
  (`/dev/diskNsN`) read-write unless the calling process is genuine
  root** (`getuid() != 0`). This is hard-coded in ntfs-3g's own source
  (`src/ntfs-3g.c`, the `ctx->blkdev` check) and applies **regardless of
  which FUSE backend you use** — macFUSE or FUSE-T, doesn't matter. It
  only doesn't apply when mounting a plain file (not a block special
  device), which is why our earlier file-backed test image could mount
  unprivileged while a real disk could not.

- **A GUI password popup
  (`osascript -e 'do shell script "..." with administrator privileges'`)
  does not grant raw disk device access, even though the resulting
  process is genuinely root.** We proved this directly: the elevated
  script printed `uid=0(root)` from `id`, and then immediately failed to
  open `/dev/diskNsN` with "Operation not permitted" anyway. This appears
  to be a TCC/Full Disk Access restriction specific to that elevation
  path (Security Agent/Authorization Services), which a normal `sudo`
  session in Terminal does not hit. Don't try to build a "friendlier"
  password popup for raw disk operations on macOS — use a real `sudo`
  re-exec (`exec sudo "$0" "$@"`) instead. It only costs the user typing
  their password in the terminal once per session.

- **`umount` (without `-f`) fails on a FUSE-T NFS-loopback mount** with
  "Operation not permitted", even run as real root via a proper `sudo`
  session. Use `umount -f`. (`diskutil unmount force` also works most of
  the time, but left a duplicate, un-removable mount table entry once
  during testing — `umount -f` was the one that was reliable every time.)

- **`diskutil info`'s "File System Personality" field can be stale**
  after formatting a raw partition directly with our own `mkntfs`,
  bypassing `diskutil`'s own formatter. It kept reporting the *old*
  filesystem type (still "MS-DOS FAT32" after the partition had already
  been overwritten with real NTFS) until something triggered a fresh
  probe — in our case, a native `diskutil mount` attempt. Don't trust a
  cached `diskutil info` result as proof a reformat failed; try an actual
  mount, or use `ntfs-3g.probe` (which reads the real on-disk structures,
  though it also needs root to open the raw device).

- **Disk identifiers (`/dev/diskN`) are not stable across reconnects.**
  The same physical drive moved between `disk15` and `disk16` multiple
  times in one session just from unmount/remount and USB
  disconnect/reconnect cycles. Never hardcode or cache a `/dev/diskN`
  path between commands — always re-resolve it live via `diskutil list`
  or `diskutil info /Volumes/<name>` immediately before each operation.

- **A Windows-origin NTFS volume with the "dirty" (unsafe shutdown) flag
  set is extremely common in practice** (improper eject, hibernation,
  power loss) and makes ntfs-3g flatly refuse a read-write mount with an
  error that reads like a permissions problem
  ("The NTFS partition is in an unsafe state..."). Always run
  `ntfsfix --clear-dirty` before mounting — it's safe and a no-op on an
  already-clean volume, so there's no reason not to run it
  unconditionally.

- **Don't blindly `diskutil unmount <device>` as a "just in case" step
  before every mount attempt without first checking whether something is
  actually mounted there.** Doing so unconditionally contributed to a
  confusing duplicate-mount situation during testing. Check the real
  mount state first (`mount | grep ...`), only unmount if something is
  actually present.

- **`ntfs-mount` reported a false "mount failed" after moving/reinstalling
  this repo, even though the mount actually worked.** Two races were
  involved: (1) calling `ntfs-3g` immediately after `diskutil unmount`
  returns can race the kernel releasing the device node, with no useful
  error printed either way; (2) FUSE-T's first mount of a session has to
  spin up its NFS loopback server, which can take a few seconds — checking
  `mount`'s output only once, 1 second after launching `ntfs-3g`, can catch
  it mid-startup and wrongly report failure. Running the *exact* same
  `ntfs-3g` command by hand right after immediately succeeded, which is
  what gave this away. Fixed by adding a settle delay before mounting and
  polling `mount` for up to 5 seconds (instead of checking once) before
  declaring failure.
  At least one later "failed, then worked when re-run" was **not** a false
  report but the mount-point bug in the next entry (2026-11-14 09:53, a
  manual `sudo ntfs-mount` right after plug-in: FUSE-T logged
  `exit status 66`; the re-run at 09:55 worked because the native mount
  was already gone).

- **Creating the mount point before unmounting macOS's own read-only
  mount leaves nothing to mount onto.** `ntfs-mount` (up to 0.2.0) did
  `mkdir -p /Volumes/<name>` *first* — a no-op, since that folder was
  the native mount's — then unmounted the native mount. macOS deletes the
  `/Volumes/<name>` folder it created as soon as that mount goes away,
  synchronously with `diskutil unmount` and within ~0.2s with `umount -f`
  (measured with an `hdiutil`-attached NTFS image). FUSE-T then runs
  `mount -t nfs ... /Volumes/<name>` on a path that no longer exists,
  `/sbin/mount` exits 66 (`invalid file system`), FUSE-T retries once,
  gives up, and ntfs-3g unmounts itself ~100ms after logging
  "Mounted ... (Read-Write)". `ntfs-3g` still exits 0, so the only trace is
  FUSE-T's log (`~/Library/Logs/fuse-t/fuse-t.log`, or
  `/var/root/Library/Logs/fuse-t/fuse-t.log` for the LaunchDaemon), which
  records the exit code but not the message. It hits *every* mount
  where the native read-only mount is present — which is always the
  case for `ntfs-autowatch` right after plug-in, so all 4 live daemon
  attempts made after Full Disk Access was granted failed this way (the
  system log shows the native mount's unmount 4-5s before each), while
  manual runs mostly happened when the native mount was already gone. Fixed in 0.2.1 by creating the folder after the unmount
  and the settle delay. Reproduced without root or the real drive: old
  sequence 3/3 failed with the identical log signature, new sequence 3/3
  mounted (plus 3/3 with `diskutil unmount` forced to fail so `umount -f`
  does the unmounting).
  Decoding hint, since FUSE-T only logs the number: `/sbin/mount` exits
  66 when the mount point doesn't exist; when `mount_nfs` itself fails it
  exits with the errno (61 connection refused, 1 operation not permitted,
  20 not a directory — all observed).

- **A `sudo` password prompt from `ntfs-mount`/`ntfs-unmount` cannot be
  satisfied from a non-interactive shell** (a CI job, an agent-run
  command, an IDE "run" panel without a real pty) — it fails outright with
  "a terminal is required to read the password". This is the same
  underlying restriction as the GUI-popup issue above (raw disk access
  needs a genuine interactive `sudo` session), just hit from a different
  angle. There's nothing to fix here: run these two scripts from an actual
  terminal.

## Auto-mount (LaunchDaemon)

- **A launchd job cannot run a script that lives under `~/Desktop`.** We
  loaded the auto-mount watcher as a test job pointing straight at this
  repo's checkout on the Desktop: launchd started it and it died instantly
  with `/bin/bash: .../bin/ntfs-autowatch: Operation not permitted`
  (exit 126), respawning in a loop. The byte-identical script copied
  outside `/Users` ran fine from the same plist. This is macOS's privacy
  protection for Desktop/Documents/Downloads applied to background jobs
  (tested in the user launchd domain; we could not load a root
  LaunchDaemon from a non-interactive shell to repeat it there). It's why
  `ntfs-autowatch --enable` refuses to register anything but the installed
  copy in `/usr/local/bin`.

- **The root LaunchDaemon needs Full Disk Access granted to the binaries
  themselves.** On the first live plug-in, the daemon's `ntfsfix` and
  `ntfs-3g` failed with `Error opening '/dev/diskNsN': Operation not
  permitted`; a `sudo` run from Terminal doesn't hit this (it had Terminal's
  access). Adding `/usr/local/bin/ntfs-3g` and `/usr/local/bin/ntfsfix`
  under Privacy & Security → Full Disk Access fixed the raw-device open.
  FUSE-T's `go-nfsv4` was added too during that session (its real file,
  `/Library/Application Support/fuse-t/bin/go-nfsv4-1.2.9`: the "+" picker
  wouldn't accept the `/usr/local/bin/go-nfsv4` symlink, dragging the real
  file from Finder worked); whether that one is actually required was not
  isolated.

- **"A LaunchDaemon has no user session, so the NFS loopback mount fails"
  was a wrong theory.** After Full Disk Access was sorted, every daemon
  attempt still failed with FUSE-T logging `exit status 66`, which looked
  like something about mounting NFS from the System launchd domain. It
  wasn't: the same image mount succeeded from a LaunchAgent in both the
  `gui/<uid>` (Aqua) and `user/<uid>` (Background, no GUI) domains, and
  the identical failure reproduced from a plain interactive shell. The
  cause was the mount-point folder (see "Mounting" above). No
  `SessionCreate`/`ProcessType`/LaunchAgent+sudoers redesign is needed.

## Performance

- **A small benchmark file measures the cache, not the disk.** Our first
  read test (64MB, written then read back) reported 1388MB/s — over a
  USB 2.0 link that physically can't exceed ~60MB/s. With 512MB and up
  (and `F_NOCACHE`), reads settled at a believable ~22MB/s. Sanity-check
  any number against the link's real ceiling before trusting it; that's
  why `tools/ntfs-bench` defaults to 1GB. Also benchmark one mount at a
  time: a Disk2 run that overlapped with a busy second FUSE-T mount wrote
  at 12.5MB/s; the same test alone, right after, gave 20.7-21.1MB/s.

- **Bigger isn't better for FUSE-T's `rwsize`.** The "obvious" tuning —
  raising the NFS transfer size from the 32KB default to
  `rwsize=1048576` — did take effect (`nfsstat -m` showed 1MB
  rsize/wsize), and made sequential writes collapse from ~600MB/s to
  11-22MB/s on an SSD-backed image (4 runs, 2 separate mounts), 30-50x
  slower; reads were fine.
  512KB was erratic too (1.26GB/s write in one round, 0.43GB/s in the
  next); only 256KB was consistently good across 5 runs. Single runs were
  noisy enough (one 64KB run wrote 300MB/s, the repeats ~900MB/s) that we
  only trust numbers repeated in separate mount sessions.

- **FUSE-T's `backend=smb` mode doesn't work with ntfs-3g here.** The
  mount comes up, but creating a file fails with "Input/output error" and
  in one case an `open()` for a new file produced a *directory*. It would
  also break `ntfs-mount`/`ntfs-unmount`, which recognize their mounts by
  the `fuse-t:` prefix in `mount` output — SMB mounts show up as
  `//Guest:@fuse-t._smb._tcp.local/...` instead.

## NTFS behavior in general

- **`rm -rf` can fail to fully delete a directory tree that previously
  held a very large number of files, even after every file inside is
  confirmed gone.** `rmdir` keeps returning "Directory not empty" on a
  directory that `ls -la` and `stat` both confirm is empty (0 entries,
  0 bytes). This is an ntfs-3g limitation: a heavily fragmented NTFS
  directory index isn't automatically compacted, and ntfs-3g
  conservatively refuses to remove the directory rather than risk data
  loss. We hit this on real, years-old Windows-created folders; a
  freshly-created directory tree (no deep history) did **not** exhibit
  the problem in testing. The only fix is a `chkdsk` pass from Windows —
  there's nothing to do about it from the Mac side.

- **`mkntfs`'s default (non-quick) zero-initialization pass can take
  hours on a large external USB drive.** It completed almost instantly
  on a small (200MB) test image, which doesn't scale linearly — on a
  real multi-terabyte USB drive at realistic (~18-20MB/s) throughput, the
  full zero-fill is a multi-hour operation. Use `-Q` (quick format) for
  anything beyond a small test volume; it's what Windows's own "quick
  format" option does too, and is entirely sufficient for a non-forensic,
  everyday use case.
