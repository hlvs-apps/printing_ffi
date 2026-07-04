#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# build-imagelibs.sh
#
# Cross-compile the PERMISSIVE image libraries needed by the cups-filters
# `imagetoraster` filter for Android arm64 (aarch64), API 24, with the NDK
# (clang). Produces STATIC libs + headers + pkg-config .pc files, staged into
#   tool/android/out/arm64-imagelibs/{lib,include,lib/pkgconfig}
# so build-cupsfilters.sh can resolve them via PKG_CONFIG_LIBDIR.
#
# Libraries (ALL permissive — NO GPL, NO AGPL, NO PDF renderer):
#   * libjpeg-turbo  (BSD-3 + IJG + zlib)   — CMake build
#   * libpng         (PNG Reference / zlib) — autotools build
#   * libtiff        (libtiff / BSD-like)   — autotools build (jpeg+zlib codecs)
#
# zlib is NOT built here: Android bionic ships libz.so on-device, and the CUPS
# cross build already links -lz. The .pc for zlib is synthesized (headers from
# the NDK sysroot) so libpng/libtiff's pkg-config `Requires: zlib` resolves.
#
# Re-runnable: tarballs cached, sources only re-extracted if missing, each lib
# only rebuilt if its staged .a is missing. `clean` wipes build/ + out.
#
# Usage:
#   tool/android/build-imagelibs.sh              # incremental
#   tool/android/build-imagelibs.sh clean        # wipe + rebuild
# ---------------------------------------------------------------------------
set -euo pipefail

# --- Paths -----------------------------------------------------------------
# OUT_ROOT / CACHE_ROOT are env-overridable (C2); defaults keep standalone runs
# unchanged, the orchestrator points them under ~/.gradle.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_ROOT="${OUT_ROOT:-$SCRIPT_DIR/out}"
CACHE_ROOT="${CACHE_ROOT:-$SCRIPT_DIR}"
IMG_DIR="$CACHE_ROOT/imagelibs"
CACHE_DIR="$IMG_DIR/cache"
BUILD_DIR="$IMG_DIR/build"
LOG_DIR="$IMG_DIR/logs"
OUT_DIR="$OUT_ROOT/arm64-imagelibs"

# --- Versions --------------------------------------------------------------
JPEG_VERSION="3.0.4"          # libjpeg-turbo
JPEG_TARBALL="libjpeg-turbo-${JPEG_VERSION}.tar.gz"
JPEG_URL="https://github.com/libjpeg-turbo/libjpeg-turbo/releases/download/${JPEG_VERSION}/${JPEG_TARBALL}"
JPEG_SRC="$BUILD_DIR/libjpeg-turbo-${JPEG_VERSION}"

PNG_VERSION="1.6.44"
PNG_TARBALL="libpng-${PNG_VERSION}.tar.xz"
PNG_URL="https://download.sourceforge.net/libpng/${PNG_TARBALL}"
PNG_SRC="$BUILD_DIR/libpng-${PNG_VERSION}"

TIFF_VERSION="4.6.0"
TIFF_TARBALL="tiff-${TIFF_VERSION}.tar.gz"
TIFF_URL="https://download.osgeo.org/libtiff/${TIFF_TARBALL}"
TIFF_SRC="$BUILD_DIR/tiff-${TIFF_VERSION}"

# --- Android NDK toolchain (same recipe as build-cups.sh) ------------------
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
SYSROOT="$TOOLCHAIN/sysroot"

if [ ! -x "$CC" ]; then
  echo "ERROR: cross compiler not found: $CC" >&2
  exit 1
fi

echo "==> Using CC=$CC"
"$CC" --version | head -1

# --- clean -----------------------------------------------------------------
if [ "${1:-}" = "clean" ]; then
  echo "==> Cleaning image-libs build tree + output"
  rm -rf "$BUILD_DIR" "$OUT_DIR"
fi

mkdir -p "$CACHE_DIR" "$BUILD_DIR" "$LOG_DIR" "$OUT_DIR/lib/pkgconfig" "$OUT_DIR/include"

# --- host env de-pollution (THE #1 gotcha, see CUPS NOTES.md) --------------
# ~/.zshrc leaks x86_64 Homebrew CPPFLAGS/LDFLAGS/PKG_CONFIG_PATH. OVERRIDE them
# (don't append). 16KB page alignment matches build-cups.sh (harmless for .a but
# consistent). No compat shim needed for these libs at API 24.
export CFLAGS="-D_GNU_SOURCE -fPIC -O2 -Wno-error"
export CXXFLAGS="$CFLAGS"
export CPPFLAGS="-D_GNU_SOURCE"
export LDFLAGS="-Wl,-z,max-page-size=16384"
export LIBS=""
export PKG_CONFIG_PATH=""
export PKG_CONFIG_LIBDIR="$OUT_DIR/lib/pkgconfig"   # ONLY our staged .pc files

download() {
  local url="$1" out="$2"
  if [ ! -f "$out" ]; then
    echo "==> Downloading $url"
    curl -L --fail -o "$out" "$url"
  else
    echo "==> Cached: $out"
  fi
}

extract() {
  local tarball="$1" srcdir="$2"
  if [ ! -d "$srcdir" ]; then
    echo "==> Extracting $(basename "$tarball")"
    case "$tarball" in
      *.tar.gz) tar -xzf "$tarball" -C "$BUILD_DIR" ;;
      *.tar.xz) tar -xJf "$tarball" -C "$BUILD_DIR" ;;
      *) echo "ERROR: unknown tarball type: $tarball" >&2; exit 1 ;;
    esac
  else
    echo "==> Source already extracted: $srcdir"
  fi
}

# ===========================================================================
# zlib .pc shim — bionic ships libz.so on-device; headers live in NDK sysroot.
# libpng/libtiff pkg-config declares `Requires: zlib` / links -lz, so provide a
# minimal zlib.pc so those resolve. We do NOT build/stage a static libz — the
# device libz.so is used at runtime (CUPS already links -lz the same way).
# ===========================================================================
if [ ! -f "$OUT_DIR/include/zlib.h" ]; then
  cp "$SYSROOT/usr/include/zlib.h" "$OUT_DIR/include/zlib.h"
  cp "$SYSROOT/usr/include/zconf.h" "$OUT_DIR/include/zconf.h"
fi
ZLIB_VER="$(sed -n 's/^#define ZLIB_VERSION "\(.*\)"/\1/p' "$OUT_DIR/include/zlib.h" | head -1)"
cat > "$OUT_DIR/lib/pkgconfig/zlib.pc" <<EOF
prefix=$OUT_DIR
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: zlib
Description: zlib compression library (Android bionic libz.so at runtime)
Version: ${ZLIB_VER:-1.2.11}
Libs: -lz
Cflags: -I\${includedir}
EOF
echo "==> Synthesized zlib.pc (version ${ZLIB_VER:-1.2.11}); runtime uses bionic libz.so"

# ===========================================================================
# libjpeg-turbo (CMake). Static only, no shared, no exec tools, no Java, no
# TurboJPEG (only the classic libjpeg API is needed by cups-filters image-jpeg).
# ===========================================================================
if [ ! -f "$OUT_DIR/lib/libjpeg.a" ]; then
  download "$JPEG_URL" "$CACHE_DIR/$JPEG_TARBALL"
  extract "$CACHE_DIR/$JPEG_TARBALL" "$JPEG_SRC"
  echo "==> Configuring + building libjpeg-turbo $JPEG_VERSION"
  JPEG_BUILD="$JPEG_SRC/build-android"
  rm -rf "$JPEG_BUILD"; mkdir -p "$JPEG_BUILD"
  ( cd "$JPEG_BUILD"
    cmake -G "Unix Makefiles" \
      -DCMAKE_TOOLCHAIN_FILE="$NDK/build/cmake/android.toolchain.cmake" \
      -DANDROID_ABI=arm64-v8a \
      -DANDROID_PLATFORM="android-$API" \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_INSTALL_PREFIX="$OUT_DIR" \
      -DCMAKE_C_FLAGS="$CFLAGS" \
      -DCMAKE_EXE_LINKER_FLAGS="$LDFLAGS" \
      -DCMAKE_SHARED_LINKER_FLAGS="$LDFLAGS" \
      -DENABLE_SHARED=OFF \
      -DENABLE_STATIC=ON \
      -DWITH_TURBOJPEG=OFF \
      -DWITH_JAVA=OFF \
      -DCMAKE_INSTALL_LIBDIR=lib \
      "$JPEG_SRC" 2>&1 | tee "$LOG_DIR/jpeg-configure.log"
    make -j"$JOBS" jpeg-static 2>&1 | tee "$LOG_DIR/jpeg-build.log"
    # `cmake --install` on the static-only target does not always stage headers;
    # stage the static lib + the 4 public headers explicitly (below), so don't
    # rely on it. Kept best-effort for completeness.
    cmake --install . 2>&1 | tee "$LOG_DIR/jpeg-install.log" || true
  )
  # Stage the static lib.
  if [ ! -f "$OUT_DIR/lib/libjpeg.a" ] && [ -f "$JPEG_BUILD/libjpeg.a" ]; then
    cp "$JPEG_BUILD/libjpeg.a" "$OUT_DIR/lib/libjpeg.a"
  fi
  [ -f "$OUT_DIR/lib/libjpeg.a" ] || { echo "ERROR: libjpeg.a not produced" >&2; exit 1; }
  # Stage the 4 public libjpeg headers. jconfig.h is GENERATED into the build dir;
  # jpeglib.h/jerror.h/jmorecfg.h are in the source dir.
  cp "$JPEG_BUILD/jconfig.h" "$OUT_DIR/include/jconfig.h"
  cp "$JPEG_SRC/jpeglib.h"   "$OUT_DIR/include/jpeglib.h"
  cp "$JPEG_SRC/jerror.h"    "$OUT_DIR/include/jerror.h"
  cp "$JPEG_SRC/jmorecfg.h"  "$OUT_DIR/include/jmorecfg.h"
  # Synthesize libjpeg.pc (libjpeg-turbo installs pkgconfig for shared; we're static).
  JPEG_LIB_VER="$(sed -n 's/^#define JPEG_LIB_VERSION *\([0-9]*\).*/\1/p' "$OUT_DIR/include/jpeglib.h" | head -1)"
  cat > "$OUT_DIR/lib/pkgconfig/libjpeg.pc" <<EOF
prefix=$OUT_DIR
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: libjpeg
Description: libjpeg-turbo (classic libjpeg API), static
Version: ${JPEG_VERSION}
Libs: -L\${libdir} -ljpeg
Cflags: -I\${includedir}
EOF
  echo "==> libjpeg-turbo staged: $OUT_DIR/lib/libjpeg.a (+ headers + libjpeg.pc)"
else
  echo "==> libjpeg already staged: $OUT_DIR/lib/libjpeg.a"
fi

# ===========================================================================
# libpng (autotools). Needs zlib (headers/pc synthesized above; -lz at runtime).
# ===========================================================================
if [ ! -f "$OUT_DIR/lib/libpng16.a" ] && [ ! -f "$OUT_DIR/lib/libpng.a" ]; then
  download "$PNG_URL" "$CACHE_DIR/$PNG_TARBALL"
  extract "$CACHE_DIR/$PNG_TARBALL" "$PNG_SRC"
  echo "==> Configuring + building libpng $PNG_VERSION"
  ( cd "$PNG_SRC"
    make distclean >/dev/null 2>&1 || true
    ./configure \
      --host="$TARGET" \
      --prefix="$OUT_DIR" \
      --libdir="$OUT_DIR/lib" \
      --disable-shared --enable-static \
      --disable-tools \
      CPPFLAGS="$CPPFLAGS -I$OUT_DIR/include" \
      LDFLAGS="$LDFLAGS -L$SYSROOT/usr/lib/$TARGET/$API" \
      2>&1 | tee "$LOG_DIR/png-configure.log"
    make -j"$JOBS" 2>&1 | tee "$LOG_DIR/png-build.log"
    make install 2>&1 | tee "$LOG_DIR/png-install.log"
  )
  echo "==> libpng staged"
else
  echo "==> libpng already staged"
fi

# ===========================================================================
# libtiff (autotools). Enable jpeg + zlib codecs (both available), disable the
# rest (no lzma/zstd/webp/jbig/lerc pulls — keep it minimal and permissive).
# ===========================================================================
if [ ! -f "$OUT_DIR/lib/libtiff.a" ]; then
  download "$TIFF_URL" "$CACHE_DIR/$TIFF_TARBALL"
  extract "$CACHE_DIR/$TIFF_TARBALL" "$TIFF_SRC"
  echo "==> Configuring + building libtiff $TIFF_VERSION"
  ( cd "$TIFF_SRC"
    make distclean >/dev/null 2>&1 || true
    ./configure \
      --host="$TARGET" \
      --prefix="$OUT_DIR" \
      --libdir="$OUT_DIR/lib" \
      --disable-shared --enable-static \
      --disable-tools --disable-tests --disable-contrib --disable-docs \
      --with-jpeg-include-dir="$OUT_DIR/include" \
      --with-jpeg-lib-dir="$OUT_DIR/lib" \
      --enable-zlib --enable-jpeg \
      --disable-old-jpeg --disable-jbig --disable-lzma \
      --disable-zstd --disable-webp --disable-lerc --disable-libdeflate \
      CPPFLAGS="$CPPFLAGS -I$OUT_DIR/include" \
      LDFLAGS="$LDFLAGS -L$OUT_DIR/lib -L$SYSROOT/usr/lib/$TARGET/$API" \
      2>&1 | tee "$LOG_DIR/tiff-configure.log"
    make -j"$JOBS" 2>&1 | tee "$LOG_DIR/tiff-build.log"
    make install 2>&1 | tee "$LOG_DIR/tiff-install.log"
  )
  echo "==> libtiff staged"
else
  echo "==> libtiff already staged"
fi

# --- verify AArch64 --------------------------------------------------------
echo ""
echo "==> Verifying staged static archives are AArch64"
for a in "$OUT_DIR"/lib/*.a; do
  [ -e "$a" ] || continue
  # llvm-nm/ar can't print arch directly for .a; extract one object and file(1) it.
  obj="$("$AR" t "$a" 2>/dev/null | head -1)"
  if [ -n "$obj" ]; then
    tmpd="$(mktemp -d)"
    ( cd "$tmpd" && "$AR" x "$a" "$obj" 2>/dev/null )
    if [ -f "$tmpd/$obj" ]; then
      arch="$("$READELF" -h "$tmpd/$obj" 2>/dev/null | awk -F: '/Machine/{gsub(/^ +/,"",$2); print $2}')"
      printf '    %-24s first obj %-28s Machine: %s\n' "$(basename "$a")" "$obj" "${arch:-?}"
    fi
    rm -rf "$tmpd"
  fi
done

echo ""
echo "==> Staged image libs (out/arm64-imagelibs):"
ls -la "$OUT_DIR/lib"/*.a 2>/dev/null || true
echo "==> pkg-config .pc files:"
ls -1 "$OUT_DIR/lib/pkgconfig"/*.pc 2>/dev/null || true
echo "==> DONE"
