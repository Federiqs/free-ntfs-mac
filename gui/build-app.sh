#!/bin/bash
# build-app.sh — build FreeNTFS.app, the menu-bar front end for free-ntfs-mac.
#
# Usage:
#   gui/build-app.sh            -> gui/build/FreeNTFS.app
#   OUT_DIR=/some/dir gui/build-app.sh
#
# Needs Xcode (or the Command Line Tools with a Swift 5.9+ toolchain).
# The app bundles a copy of install.sh, bin/ and patches/ from this checkout,
# so its "Run install.sh" button installs exactly the scripts it was built
# with. The result is ad-hoc signed: fine on the Mac that built it; another
# Mac's Gatekeeper will want a right-click → Open the first time.

set -euo pipefail

GUI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$GUI_DIR")"
OUT_DIR="${OUT_DIR:-$GUI_DIR/build}"
# Build outside the checkout: files in a checkout under ~/Desktop carry
# extended attributes that make codesign refuse the test bundle
# ("resource fork, Finder information, or similar detritus not allowed").
SCRATCH="${SCRATCH:-${TMPDIR:-/tmp}/free-ntfs-mac-gui-build}"

say() { printf '\033[1;34m==>\033[0m %s\n' "$1"; }

say "Building (release, arm64 + x86_64)..."
swift build -c release --package-path "$GUI_DIR" --scratch-path "$SCRATCH" \
  --arch arm64 --arch x86_64
BIN_DIR="$(swift build -c release --package-path "$GUI_DIR" --scratch-path "$SCRATCH" \
  --arch arm64 --arch x86_64 --show-bin-path)"

APP="$OUT_DIR/FreeNTFS.app"
CLI="$APP/Contents/Resources/cli"
say "Assembling $APP..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$CLI/bin" "$CLI/patches"
install -m 755 "$BIN_DIR/FreeNTFS" "$APP/Contents/MacOS/FreeNTFS"
install -m 644 "$GUI_DIR/Support/Info.plist" "$APP/Contents/Info.plist"
install -m 755 "$REPO_DIR/install.sh" "$CLI/install.sh"
install -m 755 "$REPO_DIR/bin/ntfs-mount" "$REPO_DIR/bin/ntfs-unmount" "$REPO_DIR/bin/ntfs-autowatch" "$CLI/bin/"
install -m 644 "$REPO_DIR"/patches/*.patch "$CLI/patches/"
install -m 644 "$REPO_DIR/LICENSE" "$APP/Contents/Resources/LICENSE"
plutil -lint -s "$APP/Contents/Info.plist"

say "Signing (ad-hoc)..."
xattr -cr "$APP"
codesign --force --sign - "$APP"
codesign --verify --strict "$APP"

say "Done: $APP"
echo "   Run it:  open \"$APP\"    (or copy it to /Applications first)"
