#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# build-cups.sh
#
# Cross-compile CUPS 2.4.x for Android arm64 (aarch64), API level 24,
# using the Android NDK (clang). Produces the cupsd scheduler, the stock
# socket/ipp/lpd backends, the cupsd helper daemons, the client tools, and
# (in static mode) the static archives libcups.a / libcupsimage.a + headers.
# Stages them (plus the data files cupsd needs to boot) into
# tool/android/out/arm64/.
#
# LINK MODE (CUPS_LINK env var, default = static):
#   CUPS_LINK=static  (DEFAULT)
#       Configures with --disable-shared --enable-static. libcups/libcupsimage
#       are built as .a archives and STATICALLY linked into every executable.
#       Result: NO libcups.so.2 to package and each binary is self-contained
#       (no NEEDED libcups.so.2). This is the Android-friendly mode — AGP only
#       packages lib*.so (no version suffix), and the dynamic loader cannot
#       find libcups.so.2. Static-linking sidesteps the whole problem.
#   CUPS_LINK=shared
#       The original spike behaviour: builds libcups.so.2 (SONAME libcups.so.2)
#       and links executables against it (NEEDED libcups.so.2). Kept for
#       reference / comparison. Do NOT use for app bundling.
#
# Re-runnable: the tarball is cached, the source tree is only re-extracted
# if missing, and configure is only re-run if needed. Pass `clean` as the
# first argument to wipe the build tree and start from scratch. NOTE: switching
# CUPS_LINK requires a clean (the choice is baked into Makedefs at configure
# time); the script auto-detects a mode mismatch and forces a reconfigure.
#
# Usage:
#   tool/android/build-cups.sh              # static (default), incremental
#   tool/android/build-cups.sh clean        # static, wipe build/ + out/ first
#   CUPS_LINK=shared tool/android/build-cups.sh clean   # legacy shared build
#
# See NOTES.md for the running log of decisions, patches, and verification.
# ---------------------------------------------------------------------------
set -euo pipefail

# --- Link mode (static vs shared) ------------------------------------------
CUPS_LINK="${CUPS_LINK:-static}"
case "$CUPS_LINK" in
  static|shared) ;;
  *) echo "ERROR: CUPS_LINK must be 'static' or 'shared' (got '$CUPS_LINK')" >&2; exit 1 ;;
esac
echo "==> Link mode: CUPS_LINK=$CUPS_LINK"

# --- Paths -----------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CACHE_DIR="$SCRIPT_DIR/cache"
BUILD_DIR="$SCRIPT_DIR/build"
OUT_DIR="$SCRIPT_DIR/out/arm64"
PATCH_DIR="$SCRIPT_DIR/patches"

CUPS_VERSION="2.4.19"
CUPS_TARBALL="cups-${CUPS_VERSION}-source.tar.gz"
CUPS_URL="https://github.com/OpenPrinting/cups/releases/download/v${CUPS_VERSION}/${CUPS_TARBALL}"
SRC_DIR="$BUILD_DIR/cups-${CUPS_VERSION}"

# --- Android NDK toolchain -------------------------------------------------
export NDK="${NDK:-/Users/henrisauer/Library/Android/sdk/ndk/27.0.12077973}"
export TOOLCHAIN="$NDK/toolchains/llvm/prebuilt/darwin-x86_64"
export API="${API:-24}"
export TARGET="${TARGET:-aarch64-linux-android}"
export PATH="$TOOLCHAIN/bin:$PATH"

export CC="$TOOLCHAIN/bin/${TARGET}${API}-clang"
export CXX="$TOOLCHAIN/bin/${TARGET}${API}-clang++"
export AR="$TOOLCHAIN/bin/llvm-ar"
export RANLIB="$TOOLCHAIN/bin/llvm-ranlib"
export STRIP="$TOOLCHAIN/bin/llvm-strip"
export NM="$TOOLCHAIN/bin/llvm-nm"
export LD="$TOOLCHAIN/bin/ld"
export READELF="$TOOLCHAIN/bin/llvm-readelf"

# Sanity check the compiler exists and is the NDK one.
if [ ! -x "$CC" ]; then
  echo "ERROR: cross compiler not found: $CC" >&2
  exit 1
fi

echo "==> Using CC=$CC"
"$CC" --version | head -1

# --- clean -----------------------------------------------------------------
if [ "${1:-}" = "clean" ]; then
  echo "==> Cleaning build tree"
  rm -rf "$BUILD_DIR" "$OUT_DIR"
  mkdir -p "$BUILD_DIR" "$OUT_DIR"
fi

mkdir -p "$CACHE_DIR" "$BUILD_DIR" "$OUT_DIR"

# --- download --------------------------------------------------------------
if [ ! -f "$CACHE_DIR/$CUPS_TARBALL" ]; then
  echo "==> Downloading $CUPS_URL"
  curl -L --fail -o "$CACHE_DIR/$CUPS_TARBALL" "$CUPS_URL"
else
  echo "==> Tarball already cached: $CACHE_DIR/$CUPS_TARBALL"
fi

# --- extract ---------------------------------------------------------------
if [ ! -d "$SRC_DIR" ]; then
  echo "==> Extracting $CUPS_TARBALL"
  tar -xzf "$CACHE_DIR/$CUPS_TARBALL" -C "$BUILD_DIR"
else
  echo "==> Source already extracted: $SRC_DIR"
fi

# --- patches ---------------------------------------------------------------
# Patches are applied idempotently: we touch a stamp file per patch.
if [ -d "$PATCH_DIR" ]; then
  for patch in "$PATCH_DIR"/*.patch; do
    [ -e "$patch" ] || continue
    stamp="$SRC_DIR/.applied-$(basename "$patch")"
    if [ -f "$stamp" ]; then
      echo "==> Patch already applied: $(basename "$patch")"
      continue
    fi
    echo "==> Applying patch: $(basename "$patch")"
    ( cd "$SRC_DIR" && patch -p1 < "$patch" )
    touch "$stamp"
  done
fi

# --- configure -------------------------------------------------------------
# Android / bionic lacks crypt(), PAM, DNS-SD, dbus, systemd, etc. Disable
# everything that needs desktop/system services. Keep shared libs so we get
# libcups.so. TLS is disabled for the spike (no gnutls/openssl cross build).
cd "$SRC_DIR"

# NOTE on flags: CUPS 2.4.x configure does NOT have separate
# --disable-gssapi / --disable-avahi / --disable-systemd / --disable-launchd /
# --disable-libusb / --disable-acl options. Instead:
#   - GSSAPI/libusb/ACL are OFF by default (opt-in via --enable-*).
#   - TLS is controlled by --with-tls=no
#   - DNS-SD (avahi/mdnsresponder) by --with-dnssd=no
#   - on-demand launch (launchd/systemd/upstart) by --with-ondemand=no
#   - DBUS by --disable-dbus, PAM by --disable-pam
CONFIGURE_FLAGS=(
  --host="$TARGET"
  --prefix=/system/cups            # on-device install prefix (runtime layout)
  --with-tls=no                    # no gnutls/openssl cross build for the spike
  --with-dnssd=no                  # no avahi/mdns on Android
  --with-ondemand=no               # no launchd/systemd/upstart
  --disable-dbus
  --disable-pam
  --disable-libusb                 # AC_ARG_ENABLE accepts this; prevents host libusb taint
  --without-rcdir                  # no SysV rc scripts
  --with-components=all            # libcups (FULL 2.x API, incl. PPD) + cupsd + backends + filters
  --with-cups-user=shell           # overridden at runtime; numeric on device
  --with-cups-group=shell
  --with-domainsocket=/data/local/tmp/cups.sock  # writable on device
)

# Link-mode flags. In static mode we disable shared libs and enable the static
# archives. config-scripts/cups-sharedlibs.m4 then sets, for --disable-shared:
#   LIBCUPS=libcups.a   LIBCUPSIMAGE=libcupsimage.a
#   LINKCUPS="../cups/libcups.a $(LIBS)"   DSO=":"   PICFLAG=0
# so cupsd + every backend/daemon link the .a directly (NO NEEDED libcups.so.2).
if [ "$CUPS_LINK" = "static" ]; then
  CONFIGURE_FLAGS+=( --disable-shared --enable-static )
else
  CONFIGURE_FLAGS+=( --enable-shared )   # explicit; shared is configure default
fi

# IMPORTANT: the host shell profile (~/.zshrc) exports CPPFLAGS / LDFLAGS /
# PKG_CONFIG_PATH pointing at x86_64 Homebrew packages (ruby, qt5, libusb).
# We must OVERRIDE (not append) all of these or the cross build gets tainted
# with host include/lib paths. We also force PKG_CONFIG_LIBDIR to an empty
# (non-existent) dir so pkg-config cannot discover any host libraries.
# Force-include the Android compat shim (crypt() + API26-gated pwent/grent
# stubs). See android-compat.h for rationale. Absolute path so it works from the
# nested build subdirs.
ANDROID_COMPAT_H="$SCRIPT_DIR/android-compat.h"
export CFLAGS="-D_GNU_SOURCE -fPIC -O2 -Wno-error -include $ANDROID_COMPAT_H"
export CPPFLAGS="-D_GNU_SOURCE -include $ANDROID_COMPAT_H"
# 16KB page alignment: Android 15+/16KB-page devices (and Google Play) require
# every loadable ELF segment to be 16384-aligned, else the loader rejects the
# binary (the app showed a "16 KB page size" warning dialog). The NDK linker
# (lld) defaults to a 4096 (0x1000) max-page-size for arm64; pass the flag to ALL
# executables and shared objects so each LOAD segment's Align becomes 0x4000.
# Goes in LDFLAGS so configure threads it into every binary's link line (cupsd,
# every backend/daemon/filter/tool). Static .a archives are unaffected (no link).
#
# STATIC C++ RUNTIME (-static-libstdc++): cups-driverd is the ONE CUPS binary
# that links C++ (it uses ../ppdc/libcupsppdc.a, the PPD compiler lib, via
# $(LD_CXX)=clang++). By default clang++ adds `NEEDED libc++_shared.so`, but when
# cupsd exec's cups-driverd on device its dynamic linker doesn't search
# nativeLibraryDir, so the exec fails with:
#   linker: CANNOT LINK EXECUTABLE "cups-driverd": library "libc++_shared.so"
#   not found: needed by main executable
# and every "add printer by ppd-name" (which forces cupsd to run cups-driverd to
# resolve the PPD) fails with "cups-driverd failed to get PPD file". Statically
# linking the C++ runtime makes cups-driverd self-contained (bionic-only), exactly
# like every other bundled binary. The flag is threaded via LDFLAGS into ALL link
# lines; it's a no-op (harmless -Wunused warning) for the C-only binaries whose
# link uses $(LD_CC)=clang, and only takes effect on the clang++ driverd link.
# Verify after build with:  llvm-readelf -d cups-driverd | grep NEEDED
# (must NOT list libc++_shared.so).
export LDFLAGS="-Wl,-z,max-page-size=16384 -static-libstdc++"
export LIBS=""
export PKG_CONFIG_PATH=""
export PKG_CONFIG_LIBDIR="$BUILD_DIR/empty-pkgconfig"
mkdir -p "$PKG_CONFIG_LIBDIR"

# Re-run configure if (a) never configured, or (b) the link mode changed since
# the last configure (the static/shared choice is baked into Makedefs, so we
# MUST reconfigure when it flips). A stamp file records the last mode used.
MODE_STAMP="$SRC_DIR/.cups-link-mode"
NEED_CONFIGURE=0
if [ ! -f "$SRC_DIR/Makedefs" ]; then
  NEED_CONFIGURE=1
elif [ ! -f "$MODE_STAMP" ] || [ "$(cat "$MODE_STAMP" 2>/dev/null)" != "$CUPS_LINK" ]; then
  echo "==> Link mode changed (was '$(cat "$MODE_STAMP" 2>/dev/null || echo unknown)', now '$CUPS_LINK'); reconfiguring + rebuilding"
  make clean >/dev/null 2>&1 || true
  NEED_CONFIGURE=1
fi

if [ "$NEED_CONFIGURE" = "1" ]; then
  echo "==> Configuring CUPS for $TARGET (API $API), link mode: $CUPS_LINK"
  ./configure "${CONFIGURE_FLAGS[@]}"
  echo "$CUPS_LINK" > "$MODE_STAMP"
else
  echo "==> Already configured for link mode '$CUPS_LINK' (Makedefs present); skipping configure"
fi

# --- build -----------------------------------------------------------------
echo "==> Building CUPS"
make -j"$(sysctl -n hw.ncpu)" || make    # fall back to serial on parallel race

echo "==> Build finished"

# --- stage -----------------------------------------------------------------
echo "==> Staging outputs into $OUT_DIR"
CUPS_LINK="$CUPS_LINK" "$SCRIPT_DIR/stage.sh"

echo "==> DONE"
