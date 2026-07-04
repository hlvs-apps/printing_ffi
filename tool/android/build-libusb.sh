#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# build-libusb.sh   (cross-compile libusb-1.0 for Android arm64)
#
# Cross-compile libusb 1.0.x for Android arm64 (aarch64), API 24, with the
# Android NDK (clang). libusb is the prerequisite for Gutenprint's dye-sub USB
# backend (`backend_gutenprint`, which contains `backend_dnpds40.c` — the DNP
# driver). See ../gutenprint/NOTES.md "libusb + DNP backend build".
#
# Produces a static `libusb-1.0.a` (+ shared .so) + headers + a pkg-config file,
# staged into tool/android/out/arm64-libusb/{lib,include,lib/pkgconfig}. That
# pkgconfig dir is what build-gutenprint.sh points PKG_CONFIG_PATH at so the DNP
# backend compiles.
#
# libusb on Android:
#   - needs --disable-udev (no udev on Android; libusb has a built-in netlink /
#     Android descriptor-wrap path).
#   - the modern Android device-access story is libusb_wrap_sys_device() with a
#     UsbManager file descriptor + LIBUSB_OPTION_NO_DEVICE_DISCOVERY; that is a
#     RUNTIME/patch concern (see the fd-handoff patch plan), NOT a build flag.
#     The library builds fine with normal (usbfs) discovery enabled.
#
# License: libusb is LGPL-2.1-or-later (safe to ship/link; does not infect the
# MIT plugin — the GPL firewall applies to the Gutenprint BACKEND, not libusb).
#
# Usage:
#   tool/android/build-libusb.sh            # incremental (idempotent)
#   tool/android/build-libusb.sh clean      # wipe build/ + out + reconfigure
# ---------------------------------------------------------------------------
set -euo pipefail

# --- Paths -----------------------------------------------------------------
# OUT_ROOT / CACHE_ROOT are env-overridable (C2) so the orchestrator can point
# every output + build tree OUT of the (read-only, git-dependency) plugin
# checkout, into ~/.gradle. Defaults keep standalone runs unchanged.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_ROOT="${OUT_ROOT:-$SCRIPT_DIR/out}"
CACHE_ROOT="${CACHE_ROOT:-$SCRIPT_DIR}"
LU_DIR="$CACHE_ROOT/libusb"
CACHE_DIR="$LU_DIR/cache"
BUILD_DIR="$LU_DIR/build"
LOG_DIR="$LU_DIR/logs"
OUT_DIR="$OUT_ROOT/arm64-libusb"

LU_VERSION="1.0.27"
LU_TARBALL="libusb-${LU_VERSION}.tar.bz2"
# Official release tarball (ships a ready ./configure — no autogen needed).
LU_URL="https://github.com/libusb/libusb/releases/download/v${LU_VERSION}/${LU_TARBALL}"
SRC_DIR="$BUILD_DIR/libusb-${LU_VERSION}"

# --- Android NDK toolchain (same recipe as build-cups.sh / build-gutenprint.sh)
export NDK="${NDK:-/Users/henrisauer/Library/Android/sdk/ndk/27.0.12077973}"
source "$SCRIPT_DIR/_android-toolchain.sh"   # sets TOOLCHAIN + JOBS (portable host tag)
export API="${API:-24}"
export TARGET="${TARGET:-aarch64-linux-android}"
export PATH="$TOOLCHAIN/bin:$PATH"

export CC="$TOOLCHAIN/bin/${TARGET}${API}-clang"
export CXX="$TOOLCHAIN/bin/${TARGET}${API}-clang++"
export AR="$TOOLCHAIN/bin/llvm-ar"
export RANLIB="$TOOLCHAIN/bin/llvm-ranlib"
export STRIP="$TOOLCHAIN/bin/llvm-strip"
export NM="$TOOLCHAIN/bin/llvm-nm"
export READELF="$TOOLCHAIN/bin/llvm-readelf"

if [ ! -x "$CC" ]; then
  echo "ERROR: cross compiler not found: $CC" >&2
  exit 1
fi

echo "==> Using CC=$CC"
"$CC" --version | head -1

mkdir -p "$CACHE_DIR" "$BUILD_DIR" "$LOG_DIR" "$OUT_DIR"

# --- clean -----------------------------------------------------------------
if [ "${1:-}" = "clean" ]; then
  echo "==> Cleaning build tree + output"
  rm -rf "$SRC_DIR" "$OUT_DIR"
  mkdir -p "$OUT_DIR"
fi

# --- download --------------------------------------------------------------
if [ ! -f "$CACHE_DIR/$LU_TARBALL" ]; then
  echo "==> Downloading $LU_URL"
  curl -L --fail -o "$CACHE_DIR/$LU_TARBALL" "$LU_URL"
else
  echo "==> Tarball already cached: $CACHE_DIR/$LU_TARBALL"
fi

# --- extract ---------------------------------------------------------------
if [ ! -d "$SRC_DIR" ]; then
  echo "==> Extracting $LU_TARBALL"
  tar -xjf "$CACHE_DIR/$LU_TARBALL" -C "$BUILD_DIR"
else
  echo "==> Source already extracted: $SRC_DIR"
fi

# --- host env de-pollution (THE #1 gotcha, see CUPS/Gutenprint NOTES.md) ----
# ~/.zshrc leaks x86_64 Homebrew CPPFLAGS/LDFLAGS/PKG_CONFIG_PATH and there is a
# HOST x86_64 libusb-1.0 in Homebrew. OVERRIDE (don't append) the compile flags
# and point pkg-config at an EMPTY libdir so NOTHING host leaks in.
export CFLAGS="-D_GNU_SOURCE -fPIC -O2 -Wno-error"
export CPPFLAGS="-D_GNU_SOURCE"
# 16KB page alignment (Android 15+/Play requirement; matches the other scripts).
export LDFLAGS="-Wl,-z,max-page-size=16384"
export LIBS=""
unset PKG_CONFIG || true
export PKG_CONFIG_PATH=""
export PKG_CONFIG_LIBDIR="$BUILD_DIR/empty-pkgconfig"
mkdir -p "$PKG_CONFIG_LIBDIR"

# --- configure -------------------------------------------------------------
cd "$SRC_DIR"

# Flags rationale:
#   --host                 cross triple -> cross-compiling mode
#   --prefix               staged install prefix (we DESTDIR-install into OUT)
#   --enable-static        we want libusb-1.0.a (static-link into the backend)
#   --enable-shared        also emit libusb-1.0.so (kept for flexibility)
#   --disable-udev         *required for Android*: no libudev; libusb falls back
#                          to its built-in Linux usbfs/netlink hotplug path
#                          (which also supports the wrap_sys_device fd handoff).
#   --disable-examples-build / --disable-tests-build  no target binaries to run.
CONFIGURE_FLAGS=(
  --host="$TARGET"
  --prefix=/system/libusb
  --enable-static
  --enable-shared
  --disable-udev
  --disable-examples-build
  --disable-tests-build
)

if [ ! -f "$SRC_DIR/Makefile" ] || [ "${1:-}" = "clean" ] || [ "${RECONFIGURE:-0}" = "1" ]; then
  echo "==> Configuring libusb $LU_VERSION for $TARGET (API $API)"
  ./configure "${CONFIGURE_FLAGS[@]}" 2>&1 | tee "$LOG_DIR/configure.log"
else
  echo "==> Already configured (Makefile present); skipping configure (RECONFIGURE=1 to force)"
fi

# --- build -----------------------------------------------------------------
echo "==> Building libusb"
( make -j"$JOBS" || make ) 2>&1 | tee "$LOG_DIR/build.log"
echo "==> Build finished"

# --- stage (DESTDIR install into a temp prefix, then flatten into OUT) ------
echo "==> Staging outputs into $OUT_DIR"
STAGE_TMP="$BUILD_DIR/stage-root"
rm -rf "$STAGE_TMP"
make install DESTDIR="$STAGE_TMP" >/dev/null 2>&1

mkdir -p "$OUT_DIR/lib/pkgconfig" "$OUT_DIR/include"
# libusb installs headers under <prefix>/include/libusb-1.0/libusb.h
cp -R "$STAGE_TMP/system/libusb/include/." "$OUT_DIR/include/"
# static + shared archives
cp "$STAGE_TMP/system/libusb/lib/libusb-1.0.a" "$OUT_DIR/lib/" 2>/dev/null || true
# copy the shared object(s), following the versioned name if present
for so in "$STAGE_TMP/system/libusb/lib/"libusb-1.0.so*; do
  [ -e "$so" ] || continue
  cp -a "$so" "$OUT_DIR/lib/"
done

# Rewrite the pkg-config file so prefix/libdir/includedir point at the STAGED
# tree (absolute paths) instead of the on-device /system/libusb prefix. This is
# what build-gutenprint.sh's PKG_CONFIG_PATH consumes so libusb_CFLAGS/_LIBS
# resolve against the cross-built archive.
PC_SRC="$STAGE_TMP/system/libusb/lib/pkgconfig/libusb-1.0.pc"
PC_DST="$OUT_DIR/lib/pkgconfig/libusb-1.0.pc"
if [ -f "$PC_SRC" ]; then
  sed -e "s|^prefix=.*|prefix=$OUT_DIR|" \
      -e "s|^exec_prefix=.*|exec_prefix=\${prefix}|" \
      -e "s|^libdir=.*|libdir=\${prefix}/lib|" \
      -e "s|^includedir=.*|includedir=\${prefix}/include|" \
      "$PC_SRC" > "$PC_DST"
  echo "==> Wrote pkg-config: $PC_DST"
else
  echo "WARNING: libusb-1.0.pc not found at $PC_SRC" >&2
fi

# --- verify ----------------------------------------------------------------
echo "==> Verifying AArch64"
echo "--- file(1) ---"
file "$OUT_DIR/lib/libusb-1.0.a" || true
for so in "$OUT_DIR/lib/"libusb-1.0.so*; do
  [ -e "$so" ] || continue
  [ -L "$so" ] && continue
  file "$so"
done
echo "--- llvm-readelf -h (first archive member + shared) ---"
# Extract one object from the archive to prove AArch64.
TMPD="$(mktemp -d)"
( cd "$TMPD" && "$AR" x "$OUT_DIR/lib/libusb-1.0.a" >/dev/null 2>&1 || true )
FIRST_OBJ="$(ls "$TMPD"/*.o 2>/dev/null | head -1 || true)"
if [ -n "$FIRST_OBJ" ]; then
  "$READELF" -h "$FIRST_OBJ" | grep -E 'Class|Machine' || true
fi
rm -rf "$TMPD"
for so in "$OUT_DIR/lib/"libusb-1.0.so; do
  [ -e "$so" ] || continue
  "$READELF" -h "$so" | grep -E 'Class|Type|Machine' || true
  echo "--- NEEDED ---"
  "$READELF" -d "$so" | grep -iE 'NEEDED|SONAME' || true
done

echo "==> DONE. Staged libusb in $OUT_DIR"
echo "    pkg-config dir: $OUT_DIR/lib/pkgconfig"
