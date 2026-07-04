#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# build-gutenprint.sh   (FEASIBILITY SPIKE — BUILD ONLY)
#
# Cross-compile Gutenprint 5.3.x for Android arm64 (aarch64), API 24, with the
# Android NDK (clang), AGAINST the already-staged cross CUPS in
# tool/android/out/arm64/{lib,include}. Goal: learn whether the CUPS raster
# filter `rastertogutenprint` (and, if reachable, the DNP dye-sub backend) build,
# and map the dependency tree. NOT integrated into the app.
#
# Outputs are staged to tool/android/out/arm64-gutenprint/ (separate from the
# CUPS staging, which is read-only here).
#
# Usage:
#   tool/android/build-gutenprint.sh            # incremental (idempotent)
#   tool/android/build-gutenprint.sh clean      # wipe build/ + out + reconfigure
#
# See tool/android/gutenprint/NOTES.md for the running log + dependency map.
# ---------------------------------------------------------------------------
set -euo pipefail

# --- Paths -----------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GP_DIR="$SCRIPT_DIR/gutenprint"
CACHE_DIR="$GP_DIR/cache"
BUILD_DIR="$GP_DIR/build"
PATCH_DIR="$GP_DIR/patches"
LOG_DIR="$GP_DIR/logs"
OUT_DIR="$SCRIPT_DIR/out/arm64-gutenprint"

# Staged cross CUPS (read-only): static libcups.a/libcupsimage.a + headers.
STAGED_CUPS="$SCRIPT_DIR/out/arm64"

# Staged cross libusb-1.0 (read-only): pkgconfig + libusb-1.0.a + headers.
# When present, the DNP / dye-sub USB backend (`backend_gutenprint`, which holds
# backend_dnpds40.c) is built; when absent, it is skipped (as in the original
# feasibility pass). Auto-detected below; force off with WITH_LIBUSB=0.
STAGED_LIBUSB="$SCRIPT_DIR/out/arm64-libusb"
STAGED_LIBUSB_PC="$STAGED_LIBUSB/lib/pkgconfig"

GP_VERSION="5.3.5"
GP_TARBALL="gutenprint-${GP_VERSION}.tar.xz"
GP_URL="https://downloads.sourceforge.net/project/gimp-print/gutenprint-5.3/${GP_VERSION}/${GP_TARBALL}"
SRC_DIR="$BUILD_DIR/gutenprint-${GP_VERSION}"

# --- Android NDK toolchain (same recipe as build-cups.sh) ------------------
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
export READELF="$TOOLCHAIN/bin/llvm-readelf"

if [ ! -x "$CC" ]; then
  echo "ERROR: cross compiler not found: $CC" >&2
  exit 1
fi

if [ ! -f "$STAGED_CUPS/lib/libcups.a" ] || [ ! -f "$STAGED_CUPS/include/cups/cups.h" ]; then
  echo "ERROR: staged cross CUPS not found at $STAGED_CUPS (need lib/libcups.a + include/cups/cups.h)." >&2
  echo "       Run tool/android/build-cups.sh first." >&2
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
if [ ! -f "$CACHE_DIR/$GP_TARBALL" ]; then
  echo "==> Downloading $GP_URL"
  curl -L --fail -o "$CACHE_DIR/$GP_TARBALL" "$GP_URL"
else
  echo "==> Tarball already cached: $CACHE_DIR/$GP_TARBALL"
fi

# --- extract ---------------------------------------------------------------
if [ ! -d "$SRC_DIR" ]; then
  echo "==> Extracting $GP_TARBALL"
  tar -xJf "$CACHE_DIR/$GP_TARBALL" -C "$BUILD_DIR"
else
  echo "==> Source already extracted: $SRC_DIR"
fi

# --- patches (idempotent, stamped) -----------------------------------------
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

# --- restore shipped xmli18n-tmp.h (cross-build helper) --------------------
# The src/xml Makefile lists xmli18n-tmp.h in CLEANFILES, so a previously failed
# build (which tried to RUN the aarch64 extract-strings on the host) may have
# deleted the SHIPPED copy. Patch 0001 stops the regeneration, but the shipped
# header must be present. Restore it from the tarball if missing.
if [ ! -f "$SRC_DIR/src/xml/xmli18n-tmp.h" ]; then
  echo "==> Restoring shipped src/xml/xmli18n-tmp.h from tarball"
  tar -xJf "$CACHE_DIR/$GP_TARBALL" -C "$BUILD_DIR" \
    "gutenprint-${GP_VERSION}/src/xml/xmli18n-tmp.h"
fi

# --- cups-config shim ------------------------------------------------------
# Materialize the cross cups-config from its template, pointing at the staged
# CUPS. Gutenprint's configure runs `cups-config` to learn CUPS CFLAGS/LIBS.
CUPS_CONFIG="$GP_DIR/cups-config-android"
sed "s|@STAGED_CUPS@|$STAGED_CUPS|g" "$GP_DIR/cups-config-android.in" > "$CUPS_CONFIG"
chmod +x "$CUPS_CONFIG"
echo "==> cups-config shim: $CUPS_CONFIG"
echo "    --cflags     : $("$CUPS_CONFIG" --cflags)"
echo "    --image --libs: $("$CUPS_CONFIG" --image --libs)"

# --- host env de-pollution (THE #1 gotcha, see CUPS NOTES.md) --------------
# ~/.zshrc leaks x86_64 Homebrew CPPFLAGS/LDFLAGS/PKG_CONFIG_PATH. OVERRIDE them
# (don't append) and force pkg-config to find NOTHING from the host. Forcing an
# empty PKG_CONFIG path ALSO makes the libusb-1.0 PKG_CHECK_MODULES fail, which
# is what we want for this build-only pass (BUILD_LIBUSB_BACKENDS=no -> the DNP /
# dye-sub USB backend is skipped; see NOTES.md "DNP backend").
# Force-include the Android compat shim (iconv stubs for API<28). Absolute path
# so it works from every nested build subdir. See android-compat-gp.h.
GP_COMPAT_H="$GP_DIR/android-compat-gp.h"
export CFLAGS="-D_GNU_SOURCE -fPIC -O2 -Wno-error -Wno-implicit-function-declaration -include $GP_COMPAT_H"
export CPPFLAGS="-D_GNU_SOURCE -include $GP_COMPAT_H"
# 16KB page alignment (Android 15+/Play requirement; matches build-cups.sh).
export LDFLAGS="-Wl,-z,max-page-size=16384"
export LIBS=""
# Keep the real pkg-config (configure requires it to exist + version-check), but
# point it at an EMPTY libdir so it discovers NO HOST libraries. We then ADD ONLY
# our cross-built libusb-1.0 (staged, AArch64) to the search path — nothing from
# the host leaks in. If the staged libusb is present, libusb-1.0 detection
# SUCCEEDS -> BUILD_LIBUSB_BACKENDS=yes -> `backend_gutenprint` (which contains
# backend_dnpds40.c, the DNP driver) is built. If it's absent (or WITH_LIBUSB=0),
# detection fails -> the USB backend is skipped (original feasibility behaviour).
unset PKG_CONFIG || true
export PKG_CONFIG_PATH=""
export PKG_CONFIG_LIBDIR="$BUILD_DIR/empty-pkgconfig"
mkdir -p "$PKG_CONFIG_LIBDIR"

WITH_LIBUSB="${WITH_LIBUSB:-auto}"
BUILD_DNP=no
if [ "$WITH_LIBUSB" != "0" ] && [ -f "$STAGED_LIBUSB_PC/libusb-1.0.pc" ] \
   && [ -f "$STAGED_LIBUSB/lib/libusb-1.0.a" ]; then
  # Prepend ONLY our staged libusb to the (empty) pkg-config libdir so
  # PKG_CHECK_MODULES([LIBUSB],[libusb-1.0]) resolves against the cross build.
  export PKG_CONFIG_LIBDIR="$STAGED_LIBUSB_PC:$PKG_CONFIG_LIBDIR"
  BUILD_DNP=yes
  echo "==> libusb-1.0 FOUND (staged): $STAGED_LIBUSB_PC — DNP/dye-sub USB backend WILL build"
  echo "    libusb CFLAGS: $(PKG_CONFIG_LIBDIR="$STAGED_LIBUSB_PC" pkg-config --cflags libusb-1.0 2>/dev/null)"
  echo "    libusb LIBS  : $(PKG_CONFIG_LIBDIR="$STAGED_LIBUSB_PC" pkg-config --libs libusb-1.0 2>/dev/null)"
  # Force the backend to STATIC-link libusb (self-contained binary, no NEEDED
  # libusb-1.0.so at runtime). PKG_CHECK_MODULES emits -lusb-1.0 which lld would
  # otherwise resolve to the shared .so; feed the absolute .a via libusb_LIBS.
  export LIBUSB_LIBS="$STAGED_LIBUSB/lib/libusb-1.0.a"
  export LIBUSB_CFLAGS="-I$STAGED_LIBUSB/include/libusb-1.0"
else
  echo "==> libusb-1.0 NOT staged (or WITH_LIBUSB=0) — DNP/dye-sub USB backend SKIPPED"
  echo "    Run tool/android/build-libusb.sh first to enable the DNP backend."
fi

# --- configure -------------------------------------------------------------
cd "$SRC_DIR"

# Flags rationale (build-only feasibility, minimize deps):
#   --host                cross triple -> sets cross-compiling mode
#   --with-cups=$STAGED   tells STP_CUPS_PATH the CUPS prefix (header fallback)
#   --with-cups-config    our shim -> CUPS CFLAGS/LIBS from the staged tree
#   --disable-nls         no gettext/iconv translation machinery
#   --disable-cups-ppds   *critical*: do NOT run the freshly-built arm64
#                         cups-genppd on the x86_64 host (it can't execute). The
#                         cups-genppd BINARY still builds; we just skip RUNNING
#                         it. PPDs are runtime data, generated on-device later.
#   --disable-test        no test programs (some run target binaries)
#   --disable-samples     no sample images
#   --disable-escputil    Epson USB util, not needed for the spike
#   --without-gimp2       no GIMP plugin (needs gtk/gimp)
#   --disable-libgutenprintui2  no GTK UI lib
#   --without-readline    no readline/ncurses
#   --without-doc         no docbook/xml doc build
#   --disable-shared --enable-static  static libgutenprint (also forces
#                         WITH_MODULES=static: drivers compiled INTO libgutenprint,
#                         no dlopen .so modules -> simpler, self-contained)
# NOTE: there is NO --disable-libusb1 flag (the task's guess); libusb is
# auto-detected via PKG_CHECK_MODULES, which we've disabled above. So the DNP/
# dye-sub USB backend is OFF for this pass by construction.
CONFIGURE_FLAGS=(
  --host="$TARGET"
  --prefix=/system/gutenprint
  --with-cups="$STAGED_CUPS"
  --with-cups-config="$CUPS_CONFIG"
  --disable-nls
  --disable-cups-ppds
  --disable-test
  --disable-samples
  --disable-escputil
  --without-gimp2
  --disable-libgutenprintui2
  --without-readline
  --without-doc
  --disable-shared
  --enable-static
)

if [ ! -f "$SRC_DIR/Makefile" ] || [ "${1:-}" = "clean" ] || [ "${RECONFIGURE:-0}" = "1" ]; then
  echo "==> Configuring Gutenprint $GP_VERSION for $TARGET (API $API)"
  set -x
  ./configure "${CONFIGURE_FLAGS[@]}" 2>&1 | tee "$LOG_DIR/configure.log"
  set +x
else
  echo "==> Already configured (Makefile present); skipping configure (RECONFIGURE=1 to force)"
fi

# --- build -----------------------------------------------------------------
echo "==> Building Gutenprint"
# Serial fallback on parallel race; capture log.
( make -j"$(sysctl -n hw.ncpu)" || make ) 2>&1 | tee "$LOG_DIR/build.log"

echo "==> Build finished"

# --- stage -----------------------------------------------------------------
echo "==> Staging outputs into $OUT_DIR"
STAGED_CUPS="$STAGED_CUPS" OUT_DIR="$OUT_DIR" SRC_DIR="$SRC_DIR" GP_VERSION="$GP_VERSION" \
  READELF="$READELF" "$GP_DIR/stage-gutenprint.sh"

echo "==> DONE"
