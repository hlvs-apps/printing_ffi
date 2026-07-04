#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# build-cupsfilters.sh
#
# Cross-compile the cups-filters `imagetoraster` filter for Android arm64
# (aarch64), API 24, with the NDK (clang), against the already-staged cross CUPS
# (tool/android/out/arm64) + the staged permissive image libs
# (tool/android/out/arm64-imagelibs). Produces the `imagetoraster` binary that
# converts image/jpeg | image/png | image/gif | image/tiff | image/bmp ->
# application/vnd.cups-raster, so a JPEG/PNG can enter the Gutenprint DNP dye-sub
# chain (imagetoraster -> rastertogutenprint.5.3 -> gutenprint53+usb backend).
#
# LICENSING (HARD CONSTRAINT — verified honored):
#   * NO PDF/PostScript renderer is built or linked: NO ghostscript, NO poppler,
#     NO mutool/MuPDF, NO qpdf. We build ONLY `libcupsfilters.la` + `imagetoraster`
#     (`make libcupsfilters.la imagetoraster`), so none of the poppler/qpdf/gs-
#     linking targets (pdftoraster, pdftopdf, gstoraster, ...) are ever compiled.
#   * imagetoraster links ONLY: staged CUPS (libcupsimage.a + libcups.a),
#     libcupsfilters.la, and the permissive image libs (libjpeg-turbo/libpng/
#     libtiff) + bionic libm/libz. NO AGPL, NO GPL PDF renderer.
#   * cups-filters 1.28.x is GPL-2.0-ish, but `imagetoraster` is exec'd by cupsd
#     as a SEPARATE process — the same license firewall as Gutenprint (LICENSING.md).
#
# cups-filters version: 1.28.17 (last 1.28.x; pairs with CUPS 2.4 / libcups2 API).
# The 2.x cups-filters targets libcups3 and would NOT link our staged CUPS 2.4.19,
# and dropped the standalone C imagetoraster filter. 1.28.17 still ships
# filter/imagetoraster.c.
#
# The generated `configure` UNCONDITIONALLY runs pkg-config for libqpdf, lcms2,
# freetype2, fontconfig — none of which imagetoraster/libcupsfilters actually LINK.
# We bypass those checks by exporting <PKG>_CFLAGS/<PKG>_LIBS to harmless values
# (the configure snippet honors env overrides and then skips pkg-config). This
# pulls in NO PDF renderer; it only lets configure complete.
#
# Re-runnable: tarball cached, source only re-extracted if missing, configure
# only re-run if needed. `clean` wipes build/ + out.
#
# Usage:
#   tool/android/build-cupsfilters.sh              # incremental
#   tool/android/build-cupsfilters.sh clean        # wipe + rebuild
# ---------------------------------------------------------------------------
set -euo pipefail

# --- Paths -----------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CF_DIR="$SCRIPT_DIR/cupsfilters"
CACHE_DIR="$CF_DIR/cache"
BUILD_DIR="$CF_DIR/build"
PATCH_DIR="$CF_DIR/patches"
LOG_DIR="$CF_DIR/logs"
OUT_DIR="$SCRIPT_DIR/out/arm64-cupsfilters"

# Staged cross CUPS (read-only): static libcups.a/libcupsimage.a + headers.
STAGED_CUPS="$SCRIPT_DIR/out/arm64"
# Staged cross image libs (read-only): libjpeg/libpng/libtiff .a + headers + .pc.
STAGED_IMG="$SCRIPT_DIR/out/arm64-imagelibs"

CF_VERSION="1.28.17"
CF_TARBALL="cups-filters-${CF_VERSION}.tar.xz"
CF_URL="https://github.com/OpenPrinting/cups-filters/releases/download/${CF_VERSION}/${CF_TARBALL}"
SRC_DIR="$BUILD_DIR/cups-filters-${CF_VERSION}"

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
  echo "ERROR: cross compiler not found: $CC" >&2; exit 1
fi
if [ ! -f "$STAGED_CUPS/lib/libcups.a" ] || [ ! -f "$STAGED_CUPS/include/cups/cups.h" ]; then
  echo "ERROR: staged cross CUPS not found at $STAGED_CUPS. Run build-cups.sh first." >&2; exit 1
fi
if [ ! -f "$STAGED_IMG/lib/libjpeg.a" ] || [ ! -f "$STAGED_IMG/lib/libpng16.a" ] || [ ! -f "$STAGED_IMG/lib/libtiff.a" ]; then
  echo "ERROR: staged image libs not found at $STAGED_IMG. Run build-imagelibs.sh first." >&2; exit 1
fi

echo "==> Using CC=$CC"
"$CC" --version | head -1

mkdir -p "$CACHE_DIR" "$BUILD_DIR" "$PATCH_DIR" "$LOG_DIR" "$OUT_DIR"

# --- clean -----------------------------------------------------------------
if [ "${1:-}" = "clean" ]; then
  echo "==> Cleaning cups-filters build tree + output"
  rm -rf "$SRC_DIR" "$OUT_DIR"
  mkdir -p "$OUT_DIR"
fi

# --- download --------------------------------------------------------------
if [ ! -f "$CACHE_DIR/$CF_TARBALL" ]; then
  echo "==> Downloading $CF_URL"
  curl -L --fail -o "$CACHE_DIR/$CF_TARBALL" "$CF_URL"
else
  echo "==> Tarball already cached: $CACHE_DIR/$CF_TARBALL"
fi

# --- extract ---------------------------------------------------------------
if [ ! -d "$SRC_DIR" ]; then
  echo "==> Extracting $CF_TARBALL"
  tar -xJf "$CACHE_DIR/$CF_TARBALL" -C "$BUILD_DIR"
else
  echo "==> Source already extracted: $SRC_DIR"
fi

# --- patches (idempotent, stamped) -----------------------------------------
if [ -d "$PATCH_DIR" ]; then
  for patch in "$PATCH_DIR"/*.patch; do
    [ -e "$patch" ] || continue
    stamp="$SRC_DIR/.applied-$(basename "$patch")"
    if [ -f "$stamp" ]; then
      echo "==> Patch already applied: $(basename "$patch")"; continue
    fi
    echo "==> Applying patch: $(basename "$patch")"
    ( cd "$SRC_DIR" && patch -p1 < "$patch" )
    touch "$stamp"
  done
fi

# --- cups-config shim ------------------------------------------------------
# Materialize a cups-config that points at the STAGED cross CUPS and emits its
# STATIC archives (reuses the gutenprint shim template). cups-filters' configure
# runs `cups-config --cflags` and `cups-config --image --libs` for CUPS_CFLAGS /
# CUPS_LIBS. The template lives with the gutenprint build; reuse it.
CUPS_CONFIG="$CF_DIR/cups-config-android"
CUPS_CONFIG_TMPL="$SCRIPT_DIR/gutenprint/cups-config-android.in"
if [ ! -f "$CUPS_CONFIG_TMPL" ]; then
  echo "ERROR: cups-config template not found: $CUPS_CONFIG_TMPL" >&2; exit 1
fi
sed "s|@STAGED_CUPS@|$STAGED_CUPS|g" "$CUPS_CONFIG_TMPL" > "$CUPS_CONFIG"
chmod +x "$CUPS_CONFIG"
echo "==> cups-config shim: $CUPS_CONFIG"
echo "    --cflags      : $("$CUPS_CONFIG" --cflags)"
echo "    --image --libs: $("$CUPS_CONFIG" --image --libs)"

# --- host env de-pollution (THE #1 gotcha, see CUPS NOTES.md) --------------
# ~/.zshrc leaks x86_64 Homebrew CPPFLAGS/LDFLAGS/PKG_CONFIG_PATH. OVERRIDE them.
# Force-include the CUPS android compat shim (crypt/pwent stubs) — cups-filters
# pulls in <cups/*.h> the same way. -D_GNU_SOURCE for getline etc.
ANDROID_COMPAT_H="$SCRIPT_DIR/android-compat.h"
export CFLAGS="-D_GNU_SOURCE -fPIC -O2 -Wno-error -Wno-implicit-function-declaration -include $ANDROID_COMPAT_H -I$STAGED_IMG/include"
export CXXFLAGS="$CFLAGS"
export CPPFLAGS="-D_GNU_SOURCE -include $ANDROID_COMPAT_H -I$STAGED_IMG/include"
# 16KB page alignment (Android 15+/Play). imagetoraster is an executable so this
# takes effect on its link line.
export LDFLAGS="-Wl,-z,max-page-size=16384 -L$STAGED_IMG/lib"
export LIBS=""

# pkg-config: point ONLY at our staged image libs (libpng16.pc, libjpeg.pc,
# zlib.pc, libtiff-4.pc). Nothing from the host leaks in.
export PKG_CONFIG_PATH=""
export PKG_CONFIG_LIBDIR="$STAGED_IMG/lib/pkgconfig"

# --- NON-LINKED pkg-config check bypasses ----------------------------------
# imagetoraster + libcupsfilters do NOT link lcms2, freetype2, fontconfig, or
# libqpdf, but the generated `configure` runs an UNCONDITIONAL pkg-config check
# for each (used by the PDF/PS filters we do NOT build). The configure snippet
# honors env overrides: `if test -n "$X_CFLAGS"; then pkg_cv_X_CFLAGS="$X_CFLAGS"`
# and then SKIPS pkg-config. Setting these to harmless (non-linking) values makes
# configure complete WITHOUT pulling in any of those libs or a PDF renderer.
# LIBS are intentionally empty of real libs (a bare -D define keeps the string
# non-empty so the override branch is taken); since we never build the targets
# that would link them, nothing references the symbols.
export LCMS_CFLAGS="-DUNUSED_LCMS";        export LCMS_LIBS=" "
export FREETYPE_CFLAGS="-DUNUSED_FREETYPE"; export FREETYPE_LIBS=" "
export FONTCONFIG_CFLAGS="-DUNUSED_FONTCONFIG"; export FONTCONFIG_LIBS=" "
export LIBQPDF_CFLAGS="-DUNUSED_QPDF";      export LIBQPDF_LIBS=" "
# glib/gio: cups-filters checks glib-2.0 UNCONDITIONALLY (used by the driverless
# utility / apple-raster path we do NOT build). Bypass the same way. gio-2.0 /
# gio-unix-2.0 are checked too (mostly under the avahi block, disabled above, but
# bypassed here for safety). imagetoraster/libcupsfilters link none of them.
export GLIB_CFLAGS="-DUNUSED_GLIB";        export GLIB_LIBS=" "
export GIO_CFLAGS="-DUNUSED_GIO";          export GIO_LIBS=" "
export GIO_UNIX_CFLAGS="-DUNUSED_GIO_UNIX"; export GIO_UNIX_LIBS=" "

# --- configure -------------------------------------------------------------
cd "$SRC_DIR"

# Flags rationale (image-only, NO PDF renderer):
#   --host                    cross triple
#   --with-cups-config        our shim -> staged static CUPS CFLAGS/LIBS
#   --enable-imagefilters     build imagetoraster (default yes; explicit)
#   --with-jpeg/png/tiff      permissive image codecs (default yes; explicit)
#   --disable-poppler         NO poppler-cpp (skips pdftoraster/pdftopdf-poppler)
#   --disable-ghostscript     NO gs (skips gstoraster/gstopdf/pdftops-gs)
#   --disable-mutool          NO mutool/MuPDF
#   --disable-exif            NO libexif (avoid extra dep; imagetoraster works w/o)
#   --disable-dbus            NO dbus (colord CMS over dbus not needed)
#   --disable-avahi           NO avahi/glib/gio (driverless/dnssd not needed)
#   --disable-braille         NO braille filter toolchain
#   --disable-mutool + gs off leaves with-pdftops=gs as a no-op default (the gs
#     binary is never built/linked; only imagetoraster is `make`d).
#   --with-pdftops=gs         choose a renderer that needs NO extra pkg (avoids the
#                             pdftocairo/poppler dev-package configure error path).
CONFIGURE_FLAGS=(
  --host="$TARGET"
  --with-cups-config="$CUPS_CONFIG"
  # STATIC libcupsfilters. A SHARED libcupsfilters.la would link the WHOLE static
  # libcups.a into the .so and hit duplicate-symbol errors, because cups-filters'
  # ppdgenerator.c re-implements several private CUPS symbols (pwgInputSlotForSource,
  # cupsStrFormatd, ...) that also live in libcups.a. Building STATIC defers symbol
  # resolution to the final imagetoraster link, where the linker only pulls the
  # objects imagetoraster actually needs (NOT ppdgenerator.o) -> no clash. This also
  # matches the static CUPS build and yields a self-contained imagetoraster binary.
  --disable-shared --enable-static
  --enable-imagefilters
  --with-jpeg --with-png
  # libtiff is DISABLED: it is optional for this task (the DNP dye-sub target is
  # photos = JPEG/PNG), and cups-filters 1.28.17 has an upstream typo where the
  # TIFF AC_SEARCH_LIBS result lands in LIBJPEG_LIBS and Makefile.in references an
  # unset $(TIFF_LIBS), so libtiff would only link via a fragile global-LIBS side
  # effect. imagetoraster still handles image/jpeg + image/png + image/gif +
  # image/bmp + the portable-anymap family without libtiff. (libtiff.a is still
  # built + staged by build-imagelibs.sh; simply not linked here.)
  --without-tiff
  --disable-poppler
  --disable-ghostscript
  --disable-mutool
  --disable-exif
  --disable-dbus
  --disable-avahi
  --disable-braille
  --with-pdftops=gs
)

if [ ! -f "$SRC_DIR/Makefile" ] || [ "${1:-}" = "clean" ] || [ "${RECONFIGURE:-0}" = "1" ]; then
  echo "==> Configuring cups-filters $CF_VERSION for $TARGET (API $API)"
  ./configure "${CONFIGURE_FLAGS[@]}" 2>&1 | tee "$LOG_DIR/configure.log"
else
  echo "==> Already configured (Makefile present); skipping (RECONFIGURE=1 to force)"
fi

# --- prove NO PDF renderer was enabled by configure ------------------------
echo ""
echo "==> configure summary (must show poppler/ghostscript/mutool = no):"
grep -E "poppler:|ghostscript:|mutool:|imagefilters:|jpeg:|png:|tiff:" "$LOG_DIR/configure.log" | sed 's/^/    /' || true
if grep -qE "poppler: *yes|ghostscript: *yes|mutool: *yes" "$LOG_DIR/configure.log"; then
  echo "FATAL: a PDF renderer (poppler/ghostscript/mutool) got enabled — ABORTING per licensing constraint." >&2
  exit 1
fi

# --- build ONLY the image filter + its library -----------------------------
# Building specific targets means the poppler/qpdf/ghostscript-linking programs
# (pdftoraster, pdftopdf, gstoraster, ...) are NEVER compiled or linked.
echo "==> Building libcupsfilters.la + imagetoraster ONLY"
make -j"$(sysctl -n hw.ncpu)" libcupsfilters.la 2>&1 | tee "$LOG_DIR/build-lib.log"
make -j"$(sysctl -n hw.ncpu)" imagetoraster 2>&1 | tee "$LOG_DIR/build-imagetoraster.log"

BIN="$SRC_DIR/imagetoraster"
# libtool may leave the real binary under .libs/
if [ ! -f "$BIN" ] && [ -f "$SRC_DIR/.libs/imagetoraster" ]; then
  BIN="$SRC_DIR/.libs/imagetoraster"
fi
[ -f "$BIN" ] || { echo "ERROR: imagetoraster binary not produced" >&2; exit 1; }
echo "==> Built: $BIN"

# --- stage -----------------------------------------------------------------
mkdir -p "$OUT_DIR/filter"
cp "$BIN" "$OUT_DIR/filter/imagetoraster"
chmod +x "$OUT_DIR/filter/imagetoraster"
echo "==> Staged: $OUT_DIR/filter/imagetoraster"

# --- VERIFY: AArch64 PIE, 16KB align, NO PDF-renderer deps -----------------
echo ""
echo "==> VERIFY imagetoraster"
echo "--- file / readelf -h (expect AArch64 PIE) ---"
"$READELF" -h "$OUT_DIR/filter/imagetoraster" | grep -E "Class|Type|Machine" | sed 's/^/    /'
echo "--- readelf -d NEEDED (expect ONLY bionic: libc/libm/libdl/libz [+ libc++_shared]) ---"
"$READELF" -d "$OUT_DIR/filter/imagetoraster" | grep -i NEEDED | sed 's/^/    /'
echo "--- 16KB page alignment (every LOAD Align must be 0x4000) ---"
"$READELF" -l "$OUT_DIR/filter/imagetoraster" | awk '/LOAD/{print "    LOAD Align:", $NF}'
echo "--- PROOF: NO ghostscript/poppler/mutool/qpdf NEEDED or symbols ---"
if "$READELF" -d "$OUT_DIR/filter/imagetoraster" | grep -iE "poppler|ghostscript|gs\.so|mutool|mupdf|qpdf" ; then
  echo "FATAL: a PDF-renderer library is NEEDED by imagetoraster — ABORTING." >&2
  exit 1
else
  echo "    OK: no poppler/ghostscript/mutool/qpdf in NEEDED"
fi
if "$NM" -uC "$OUT_DIR/filter/imagetoraster" 2>/dev/null | grep -iE "poppler|Ghostscript|qpdf|mupdf|fz_|QPDF" ; then
  echo "FATAL: a PDF-renderer symbol is referenced by imagetoraster — ABORTING." >&2
  exit 1
else
  echo "    OK: no poppler/qpdf/mupdf undefined symbols"
fi

echo ""
echo "==> DONE. imagetoraster staged at $OUT_DIR/filter/imagetoraster"
