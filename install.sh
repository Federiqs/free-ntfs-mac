#!/bin/bash
# install.sh — one-shot installer for read-write NTFS support on macOS,
# using ntfs-3g (Tuxera, GPLv2) linked against FUSE-T (no kext, no SIP changes).
#
# Usage:
#   ./install.sh
#
# What it does, with as little manual intervention as possible:
#   1. Checks for Xcode Command Line Tools and Homebrew (prerequisites you
#      must already have — we don't silently install Homebrew for you).
#   2. Installs build dependencies and FUSE-T via Homebrew.
#   3. Clones macos-fuse-t/ntfs-3g, applies our macOS install-path patch.
#   4. Builds and installs ntfs-3g linked against FUSE-T into /usr/local.
#   5. Installs the ntfs-mount / ntfs-unmount / ntfs-autowatch helper scripts.
#      Auto-mount on plug-in is NOT enabled — it's a separate, explicit
#      opt-in (ntfs-autowatch --enable), see README.
#
# You will be asked for your password ONCE (sudo keep-alive handles the rest).

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${TMPDIR:-/tmp}/free-ntfs-mac-build"
NTFS3G_REPO="https://github.com/macos-fuse-t/ntfs-3g.git"
PREFIX="${PREFIX:-/usr/local}"

say()  { printf '\033[1;34m==>\033[0m %s\n' "$1"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$1"; }
die()  { printf '\033[1;31mERRORE:\033[0m %s\n' "$1" >&2; exit 1; }

# --- 0. Prerequisites -------------------------------------------------------
command -v xcode-select >/dev/null 2>&1 && xcode-select -p >/dev/null 2>&1 \
  || die "Xcode Command Line Tools non installati. Esegui: xcode-select --install"

command -v brew >/dev/null 2>&1 \
  || die "Homebrew non trovato. Installalo da https://brew.sh e rilancia questo script."

say "Prerequisiti OK (Xcode CLT, Homebrew)."

# --- 1. Ask for sudo once, keep it alive for the whole script ---------------
say "Serve la password per installare FUSE-T e i binari in /usr/local (una sola volta)."
sudo -v
( while true; do sudo -n true; sleep 60; kill -0 "$$" 2>/dev/null || exit; done ) 2>/dev/null &
SUDO_KEEPALIVE_PID=$!
trap 'kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true' EXIT

# --- 2. Build dependencies via Homebrew -------------------------------------
say "Installo le dipendenze di build (autoconf, automake, libtool, pkgconf, m4, gnutls, libgcrypt, git)..."
brew install autoconf automake libtool pkgconf m4 gnutls libgcrypt git >/dev/null

say "Installo FUSE-T (filesystem in userspace, nessuna kext, nessun cambiamento a SIP)..."
brew install --cask fuse-t

# --- 3. Fetch and patch ntfs-3g ---------------------------------------------
say "Scarico il sorgente di ntfs-3g (fork macos-fuse-t)..."
rm -rf "$BUILD_DIR"
git clone --depth 1 "$NTFS3G_REPO" "$BUILD_DIR"

say "Applico la patch per i percorsi di installazione macOS..."
git -C "$BUILD_DIR" apply "$REPO_DIR/patches/0001-fix-macos-install-hook.patch"

# --- 4. Build -----------------------------------------------------------
say "Genero lo script di configurazione (autoreconf)..."
( cd "$BUILD_DIR" && autoreconf --verbose --install --force >/tmp/free-ntfs-mac-autoreconf.log 2>&1 ) \
  || die "autoreconf fallito, log in /tmp/free-ntfs-mac-autoreconf.log"

say "Configuro la build contro FUSE-T..."
( cd "$BUILD_DIR" && ./configure \
    --prefix="$PREFIX" \
    --bindir="$PREFIX/bin" \
    --sbindir="$PREFIX/bin" \
    --with-fuse=external \
    FUSE_CFLAGS="-I/usr/local/include/fuse" \
    FUSE_LIBS="-L/usr/local/lib -Wl,-rpath,/usr/local/lib -lfuse-t" \
    LDFLAGS="-Wl,-headerpad_max_install_names" \
    >/tmp/free-ntfs-mac-configure.log 2>&1 ) \
  || die "configure fallito, log in /tmp/free-ntfs-mac-configure.log"

say "Compilo (può richiedere qualche minuto)..."
( cd "$BUILD_DIR" && make -j"$(sysctl -n hw.ncpu)" >/tmp/free-ntfs-mac-make.log 2>&1 ) \
  || die "make fallito, log in /tmp/free-ntfs-mac-make.log"

say "Installo in $PREFIX/bin (richiede i permessi di root, già autorizzati sopra)..."
( cd "$BUILD_DIR" && sudo make install \
    rootbindir="$PREFIX/bin" \
    rootsbindir="$PREFIX/bin" \
    >/tmp/free-ntfs-mac-install.log 2>&1 ) \
  || die "make install fallito, log in /tmp/free-ntfs-mac-install.log"

# The build system doesn't reliably propagate -Wl,-rpath from FUSE_LIBS into
# the final link step, so the installed binaries don't know where to find
# their libraries at runtime. Fix it directly on the installed binaries —
# this is the one part of the whole pipeline that needs a manual nudge, and
# install_name_tool is the proven, reliable way to do it.
#
# Two rpaths are needed: $PREFIX/lib for our own libntfs-3g.dylib, and
# /usr/local/lib for FUSE-T's libfuse-t.dylib — FUSE-T always installs there
# via its Homebrew cask regardless of what PREFIX we use for ntfs-3g itself.
say "Correggo il percorso delle librerie nei binari installati..."
for bin in ntfs-3g lowntfs-3g; do
  sudo install_name_tool -add_rpath "$PREFIX/lib" "$PREFIX/bin/$bin" 2>/dev/null || true
  if [ "$PREFIX/lib" != "/usr/local/lib" ]; then
    sudo install_name_tool -add_rpath "/usr/local/lib" "$PREFIX/bin/$bin" 2>/dev/null || true
  fi
done

# --- 5. Install helper scripts ----------------------------------------------
say "Installo gli script ntfs-mount / ntfs-unmount / ntfs-autowatch in $PREFIX/bin..."
sudo install -m 755 "$REPO_DIR/bin/ntfs-mount"     "$PREFIX/bin/ntfs-mount"
sudo install -m 755 "$REPO_DIR/bin/ntfs-unmount"   "$PREFIX/bin/ntfs-unmount"
sudo install -m 755 "$REPO_DIR/bin/ntfs-autowatch" "$PREFIX/bin/ntfs-autowatch"

# --- 6. Verify ----------------------------------------------------------
say "Verifica finale..."
"$PREFIX/bin/ntfs-3g" --version || die "ntfs-3g installato ma non eseguibile — controlla i log sopra."

echo
say "Fatto! Collega un disco NTFS e lancia:  ntfs-mount"
echo "   (rileva da solo i volumi NTFS collegati e li monta in scrittura — ti chiede la password una volta sola)"
echo
echo "   Facoltativo — montaggio automatico ogni volta che colleghi un disco NTFS:"
echo "     ntfs-autowatch --enable      (per disattivarlo: ntfs-autowatch --disable)"
