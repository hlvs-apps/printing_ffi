#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# build_cups_android.sh — cached, idempotent orchestrator that cross-compiles
# CUPS + cups-filters + Gutenprint + libusb + image libs for ONE Android ABI and
# stages the result for the printing_ffi Flutter FFI plugin.
#
# Invoked once per ABI by android/CMakeLists.txt (execute_process, at CMake
# CONFIGURE time — before add_library/link, so the staged libcups.a is guaranteed
# present). Mirrors flutter_fotobox_gphoto's build_gphoto2_android.sh.
#
# Inputs come from the environment (the "env contract"):
#   ABI          arm64-v8a  (the only ABI CUPS cross-builds today)
#   MIN_SDK      minimum Android API level (e.g. 24)
#   NDK          absolute path to the Android NDK (r27 / 27.0.12077973)
#   STAGE_DIR    output: <dir>/{include,lib} — libcups.a/libcupsimage.a + headers
#                that android/CMakeLists.txt links into libprinting_ffi.so
#   JNILIBS_DIR  output: the runtime lib*.so set packaged into the APK (cupsd,
#                backends, filters, cgi, gutenprint backend/filters, libc++_shared)
#   ASSETS_DIR   output: share/cups + share/gutenprint, packaged as APK assets
#   CACHE_DIR    downloaded sources + build trees + staged out/ (reused across
#                builds; lives under ~/.gradle so it survives `flutter clean`)
#
# Design:
#  * Runs the 5 existing tool/android/build-*.sh scripts (libusb -> imagelibs ->
#    cups -> cupsfilters -> gutenprint) with OUT_ROOT + CACHE_ROOT redirected under
#    CACHE_DIR (C2), so nothing is written into the (read-only) plugin checkout.
#  * A cache marker keyed on the pinned source versions gives an instant no-op on
#    rebuild — but only when the staged libcups.a + the runtime .so are ACTUALLY
#    present (a partial clean must not be trusted).
#  * Android only accepts flat, unversioned lib*.so. Every runtime executable is
#    copied under its lib*.so name (see jnilibs-map.md), soname-flattened + stripped
#    with patchelf, and 16 KB-aligned (C5) — asserted below.
#  * The staged .so set MUST match the symlink-farm names printing_ffi.c expects
#    (C6) — asserted against EXPECTED_SO below, not just a count.
# ---------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- env contract ----------------------------------------------------------
: "${ABI:?build_cups_android.sh: ABI must be set (env contract)}"
: "${MIN_SDK:?build_cups_android.sh: MIN_SDK must be set (env contract)}"
: "${NDK:?build_cups_android.sh: NDK must be set (env contract)}"
: "${STAGE_DIR:?build_cups_android.sh: STAGE_DIR must be set (env contract)}"
: "${JNILIBS_DIR:?build_cups_android.sh: JNILIBS_DIR must be set (env contract)}"
: "${ASSETS_DIR:?build_cups_android.sh: ASSETS_DIR must be set (env contract)}"
: "${CACHE_DIR:?build_cups_android.sh: CACHE_DIR must be set (env contract)}"

# CUPS only cross-builds for arm64-v8a today (see build-cups.sh + src/CMakeLists).
if [ "$ABI" != "arm64-v8a" ]; then
  echo "ERROR: printing_ffi cross-builds CUPS only for arm64-v8a (got ABI='$ABI')." >&2
  echo "       Restrict the app to arm64-v8a (abiFilters / -PcupsAbis=arm64-v8a)." >&2
  exit 1
fi

# --- pinned source versions (part of the cache key; keep in sync with the
#     build-*.sh scripts) -----------------------------------------------------
LIBUSB_VER=1.0.27
JPEG_VER=3.0.4
PNG_VER=1.6.44
TIFF_VER=4.6.0
CUPS_VER=2.4.19
CUPSFILTERS_VER=1.28.17
GUTENPRINT_VER=5.3.5

# --- 1. host detect (Darwin/Linux ok; native Windows -> WSL2) ---------------
case "$(uname -s)" in
  Darwin | Linux) ;;
  MINGW* | MSYS* | CYGWIN* | "")
    echo "printing_ffi: build the Android target under WSL2." >&2
    echo "  The CUPS/Gutenprint cross-compile needs a POSIX host (autotools + patchelf)." >&2
    echo "  Native Windows can't run it; install WSL2 and build from the Ubuntu shell." >&2
    exit 1
    ;;
  *)
    echo "printing_ffi: unsupported build host '$(uname -s)'. Use macOS, Linux, or WSL2." >&2
    exit 1
    ;;
esac

# --- 2. preflight host tools (fail fast, clear per-OS hints) ----------------
_missing=""
for t in autoconf automake libtool make pkg-config bash curl tar patchelf; do
  command -v "$t" >/dev/null 2>&1 || _missing="$_missing $t"
done
if [ -n "$_missing" ]; then
  echo "ERROR: printing_ffi needs these host tools to cross-compile CUPS from source:$_missing" >&2
  echo "  macOS:  brew install autoconf automake libtool pkg-config patchelf" >&2
  echo "  Ubuntu/WSL2: sudo apt-get install autoconf automake libtool pkg-config patchelf make curl" >&2
  exit 1
fi
# Checksum helpers for the tarball integrity check (C3) + the cache key.
# SHASUM hashes a file; SHASTDIN hashes stdin.
if command -v shasum >/dev/null 2>&1; then
  SHASUM() { shasum -a256 "$1" | cut -d' ' -f1; }
  SHASTDIN() { shasum -a256 | cut -d' ' -f1; }
elif command -v sha256sum >/dev/null 2>&1; then
  SHASUM() { sha256sum "$1" | cut -d' ' -f1; }
  SHASTDIN() { sha256sum | cut -d' ' -f1; }
else
  echo "ERROR: need shasum or sha256sum for source integrity checks." >&2
  exit 1
fi

# --- 3. toolchain (sources _android-toolchain.sh: WSL2 detect + portable NDK
#     host tag + JOBS) ---------------------------------------------------------
export NDK
source "$SCRIPT_DIR/_android-toolchain.sh"   # sets TOOLCHAIN, HOST_TAG, JOBS
READELF="$TOOLCHAIN/bin/llvm-readelf"
STRIP="$TOOLCHAIN/bin/llvm-strip"
PATCHELF="$(command -v patchelf)"

# --- 4. roots: everything under CACHE_DIR (out of the plugin checkout, C2) ---
OUT_ROOT="$CACHE_DIR/out"          # per-lib staged trees (out/arm64, out/arm64-*)
CACHE_ROOT="$CACHE_DIR/work"       # per-lib download + extract + build trees
mkdir -p "$OUT_ROOT" "$CACHE_ROOT" "$STAGE_DIR/lib" "$STAGE_DIR/include" \
         "$JNILIBS_DIR" "$ASSETS_DIR"
export OUT_ROOT CACHE_ROOT
export API="$MIN_SDK" MIN_SDK NDK

# --- stable compat-shim copies (absolute -include path must NOT dangle) ------
# The build-*.sh scripts force-include android-compat.h / android-compat-gp.h by
# ABSOLUTE path, and autotools bakes that path into the cached build trees
# (Makefiles, Makedefs, config.status, libtool, automake .deps/*.Po). SCRIPT_DIR
# here is the plugin CHECKOUT — a pub-cache git dir keyed by commit
# (~/.pub-cache/git/printing_ffi-<sha>/) or a Conductor worktree. Both are
# replaced wholesale on a new commit / new worktree, and the old one is deleted.
# The cache (under ~/.gradle) survives, so its baked -include path then points at
# a vanished dir and every later `make` dies with:
#   "No rule to make target '.../tool/android/android-compat.h'".
# Fix: copy the shims into the persistent cache (shared + stable across checkouts)
# and point the sub-builds at THOSE copies. Content-aware copy so an unchanged
# shim keeps its mtime (no spurious recompiles); a changed shim propagates and
# make rebuilds the objects that depend on it.
COMPAT_DIR="$CACHE_DIR/compat"
mkdir -p "$COMPAT_DIR"
copy_stable_compat() { # <src> <dst>
  local src="$1" dst="$2"
  [ -f "$src" ] || { echo "ERROR: compat shim source missing: $src" >&2; exit 1; }
  if [ ! -f "$dst" ] || ! cmp -s "$src" "$dst"; then
    cp -f "$src" "$dst"
  fi
}
copy_stable_compat "$SCRIPT_DIR/android-compat.h"               "$COMPAT_DIR/android-compat.h"
copy_stable_compat "$SCRIPT_DIR/gutenprint/android-compat-gp.h" "$COMPAT_DIR/android-compat-gp.h"
export ANDROID_COMPAT_H="$COMPAT_DIR/android-compat.h"
export GP_COMPAT_H="$COMPAT_DIR/android-compat-gp.h"

# The staged CUPS static libs that CMake links.
CUPS_OUT="$OUT_ROOT/arm64"
CUPSFILTERS_OUT="$OUT_ROOT/arm64-cupsfilters"
GUTENPRINT_OUT="$OUT_ROOT/arm64-gutenprint"

# --- cache marker ----------------------------------------------------------
# Key = ABI + MIN_SDK + NDK dir + every pinned source version + the produced-so
# set. Only trust the marker when the promised outputs are actually present.
KEY="$(printf '%s' \
  "$ABI|$MIN_SDK|$(basename "$NDK")|$LIBUSB_VER|$JPEG_VER|$PNG_VER|$TIFF_VER|$CUPS_VER|$CUPSFILTERS_VER|$GUTENPRINT_VER" \
  | SHASTDIN)"
MARKER="$STAGE_DIR/.built-$KEY"

if [ -f "$MARKER" ] \
   && [ -f "$STAGE_DIR/lib/libcups.a" ] \
   && [ -f "$JNILIBS_DIR/libcupsd.so" ] \
   && [ -f "$JNILIBS_DIR/libcupsbe_gutenprint53usb.so" ] \
   && [ -f "$ASSETS_DIR/cups/share/cups/templates/header.tmpl" ]; then
  echo "[$ABI] printing_ffi CUPS already built ($KEY) — skipping"
  exit 0
fi
# Stale marker / partial outputs: clean the flattened outputs for a fresh stage
# (the per-lib build trees under CACHE_ROOT are kept — they are idempotent).
rm -f "$STAGE_DIR"/.built-* 2>/dev/null || true
rm -f "$JNILIBS_DIR"/*.so 2>/dev/null || true

echo "==============================================================="
echo " printing_ffi: cross-compiling CUPS stack for $ABI (API $MIN_SDK)"
echo "   NDK       : $NDK ($HOST_TAG, $JOBS jobs)"
echo "   OUT_ROOT  : $OUT_ROOT"
echo "   CACHE_ROOT: $CACHE_ROOT"
echo "==============================================================="

# ---------------------------------------------------------------------------
# C3 — verify the SHA256 of each pinned source tarball. The per-lib scripts pin
# the versions + download; we cross-check the integrity of the cached tarballs
# here so a corrupt/tampered download can't silently poison the build. (libusb +
# gutenprint already carry SHA-checks in their own scripts; the rest are verified
# here.) The check runs AFTER each build step downloads into CACHE_ROOT.
# ---------------------------------------------------------------------------
check_sha() { # <expected-sha> <file>
  local sha="$1" f="$2"
  [ -f "$f" ] || { echo "  (not yet downloaded: $(basename "$f"))"; return 0; }
  local got; got="$(SHASUM "$f")"
  if [ "$got" != "$sha" ]; then
    echo "ERROR: SHA256 mismatch for $(basename "$f")" >&2
    echo "  expected $sha" >&2
    echo "  got      $got" >&2
    exit 1
  fi
  echo "  sha256 OK: $(basename "$f")"
}

run_step() { # <label> <script> [args...]
  local label="$1"; shift
  echo ""
  echo "---------- [$ABI] $label ----------"
  bash "$@"
}

# --- 5a. libusb (LGPL; DNP backend prereq) ---------------------------------
run_step "libusb $LIBUSB_VER"       "$SCRIPT_DIR/build-libusb.sh"
# --- 5b. permissive image libs (imagetoraster codecs) ----------------------
run_step "image libs (jpeg/png/tiff)" "$SCRIPT_DIR/build-imagelibs.sh"
# --- 5c. CUPS (static libcups.a + cupsd + backends/filters/daemons/cgi) -----
CUPS_LINK=static run_step "CUPS $CUPS_VER" "$SCRIPT_DIR/build-cups.sh"
# --- 5d. cups-filters imagetoraster ----------------------------------------
run_step "cups-filters $CUPSFILTERS_VER (imagetoraster)" "$SCRIPT_DIR/build-cupsfilters.sh"
# --- 5e. Gutenprint (DNP dye-sub backend/filter + genppd + xml data) --------
run_step "Gutenprint $GUTENPRINT_VER" "$SCRIPT_DIR/build-gutenprint.sh"

# --- C3: verify pinned tarball checksums now they're all downloaded ---------
echo ""
echo "---------- [$ABI] C3: source tarball integrity ----------"
check_sha ffaa41d741a8a3bee244ac8e54a72ea05bf2879663c098c82fc5757853441575 \
  "$CACHE_ROOT/libusb/cache/libusb-${LIBUSB_VER}.tar.bz2"
check_sha 99130559e7d62e8d695f2c0eaeef912c5828d5b84a0537dcb24c9678c9d5b76b \
  "$CACHE_ROOT/imagelibs/cache/libjpeg-turbo-${JPEG_VER}.tar.gz"
check_sha 60c4da1d5b7f0aa8d158da48e8f8afa9773c1c8baa5d21974df61f1886b8ce8e \
  "$CACHE_ROOT/imagelibs/cache/libpng-${PNG_VER}.tar.xz"
check_sha 88b3979e6d5c7e32b50d7ec72fb15af724f6ab2cbf7e10880c360a77e4b5d99a \
  "$CACHE_ROOT/imagelibs/cache/tiff-${TIFF_VER}.tar.gz"
check_sha 820984b12a67f98705785aae2dd1347fe0ac097828001d4583ff64574aed6389 \
  "$CACHE_ROOT/cups/cache/cups-${CUPS_VER}-source.tar.gz"
check_sha 270a3752a960368aa99d431fb5d34f4039b2ac943c576d840612d1d8185c9bb9 \
  "$CACHE_ROOT/cupsfilters/cache/cups-filters-${CUPSFILTERS_VER}.tar.xz"
check_sha f5a9f47de28530b1ae2069cfbc647a9a641baeeabe809bb0ef2b3ec5b9668d70 \
  "$CACHE_ROOT/gutenprint/cache/gutenprint-${GUTENPRINT_VER}.tar.xz"

# ---------------------------------------------------------------------------
# 6. Flatten + strip the runtime executables into JNILIBS_DIR under their
#    lib*.so names. Each is a self-contained PIE (static libcups); patchelf
#    flattens any versioned soname/NEEDED and strip shrinks it. 16 KB alignment
#    (C5) is already set at link time by every build-*.sh LDFLAGS; asserted below.
# ---------------------------------------------------------------------------
echo ""
echo "---------- [$ABI] staging runtime lib*.so into JNILIBS_DIR ----------"

flatten() { # <src-exe> <flatname.so>
  local src="$1" flat="$2"
  if [ ! -f "$src" ]; then
    echo "ERROR: expected runtime binary missing: $src (-> $flat)" >&2
    exit 1
  fi
  cp -f "$src" "$JNILIBS_DIR/$flat"
  "$PATCHELF" --set-soname "$flat" "$JNILIBS_DIR/$flat" 2>/dev/null || true
  "$PATCHELF" --print-needed "$JNILIBS_DIR/$flat" 2>/dev/null | while read -r need; do
    case "$need" in
      *.so.*) "$PATCHELF" --replace-needed "$need" "${need%%.so.*}.so" "$JNILIBS_DIR/$flat" 2>/dev/null || true ;;
    esac
  done
  "$STRIP" --strip-unneeded "$JNILIBS_DIR/$flat" 2>/dev/null || true
}

# CUPS core: cupsd, backends, daemon helpers, filters, cgi, client tools.
flatten "$CUPS_OUT/sbin/cupsd"                          libcupsd.so
for be in socket ipp lpd snmp usb http; do
  flatten "$CUPS_OUT/lib/cups/backend/$be"             "libcupsbe_${be}.so"
done
flatten "$CUPS_OUT/lib/cups/daemon/cups-deviced"        libcupsd_deviced.so
flatten "$CUPS_OUT/lib/cups/daemon/cups-driverd"        libcupsd_driverd.so
flatten "$CUPS_OUT/lib/cups/daemon/cups-exec"           libcupsd_exec.so
flatten "$CUPS_OUT/lib/cups/daemon/cups-lpd"            libcupsd_lpd.so
flatten "$CUPS_OUT/lib/cups/daemon/cupsfilter"          libcupsd_cupsfilter.so
for f in gziptoany pstops commandtops rastertopwg rastertoepson rastertohp rastertolabel; do
  flatten "$CUPS_OUT/lib/cups/filter/$f"               "libcupsf_${f}.so"
done
for c in admin printers jobs classes help; do
  flatten "$CUPS_OUT/lib/cups/cgi-bin/$c.cgi"          "libcupscgi_${c}.so"
done
for t in lp lpadmin lpstat; do
  flatten "$CUPS_OUT/bin/$t"                           "libcupstool_${t}.so"
done

# cups-filters: imagetoraster (image/jpeg|png -> cups-raster).
flatten "$CUPSFILTERS_OUT/filter/imagetoraster"         libcupsf_imagetoraster.so

# Gutenprint DNP dye-sub add-ons (GPL, separately exec'd — license firewall).
flatten "$GUTENPRINT_OUT/cups/backend/gutenprint53+usb" libcupsbe_gutenprint53usb.so
flatten "$GUTENPRINT_OUT/cups/filter/rastertogutenprint.5.3" libcupsf_rastertogutenprint.so
flatten "$GUTENPRINT_OUT/cups/filter/commandtodyesub"   libcupsf_commandtodyesub.so
flatten "$GUTENPRINT_OUT/bin/cups-genppd.5.3"           libcupstool_gutenprint_genppd.so

# libc++_shared.so — cups-driverd's one non-bionic dep. Ship the NDK copy.
LIBCXX="$TOOLCHAIN/sysroot/usr/lib/aarch64-linux-android/libc++_shared.so"
if [ -f "$LIBCXX" ]; then
  cp -f "$LIBCXX" "$JNILIBS_DIR/libc++_shared.so"
  "$STRIP" --strip-unneeded "$JNILIBS_DIR/libc++_shared.so" 2>/dev/null || true
else
  echo "ERROR: NDK libc++_shared.so not found at $LIBCXX" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# C6 — assert the produced .so set EXACTLY matches the symlink-farm names the C
# runtime (src/printing_ffi.c build_symlink_farm + start_cups_server) expects,
# plus the client tools + libc++_shared. Not "34 libs" — the exact set.
# ---------------------------------------------------------------------------
echo ""
echo "---------- [$ABI] C6: symlink-farm name assertion ----------"
EXPECTED_SO="$(cat <<'EOF'
libc++_shared.so
libcupsbe_gutenprint53usb.so
libcupsbe_http.so
libcupsbe_ipp.so
libcupsbe_lpd.so
libcupsbe_snmp.so
libcupsbe_socket.so
libcupsbe_usb.so
libcupscgi_admin.so
libcupscgi_classes.so
libcupscgi_help.so
libcupscgi_jobs.so
libcupscgi_printers.so
libcupsd.so
libcupsd_cupsfilter.so
libcupsd_deviced.so
libcupsd_driverd.so
libcupsd_exec.so
libcupsd_lpd.so
libcupsf_commandtodyesub.so
libcupsf_commandtops.so
libcupsf_gziptoany.so
libcupsf_imagetoraster.so
libcupsf_pstops.so
libcupsf_rastertoepson.so
libcupsf_rastertogutenprint.so
libcupsf_rastertohp.so
libcupsf_rastertolabel.so
libcupsf_rastertopwg.so
libcupstool_gutenprint_genppd.so
libcupstool_lp.so
libcupstool_lpadmin.so
libcupstool_lpstat.so
EOF
)"
PRODUCED_SO="$(cd "$JNILIBS_DIR" && ls -1 ./*.so 2>/dev/null | sed 's#^\./##' | sort)"
EXPECTED_SORTED="$(printf '%s\n' "$EXPECTED_SO" | sort)"
if [ "$PRODUCED_SO" != "$EXPECTED_SORTED" ]; then
  echo "ERROR: staged .so set does not match the C symlink-farm expectation (C6)." >&2
  echo "--- only expected (missing from build) ---" >&2
  comm -23 <(printf '%s\n' "$EXPECTED_SORTED") <(printf '%s\n' "$PRODUCED_SO") | sed 's/^/  /' >&2
  echo "--- only produced (unexpected extra) ---" >&2
  comm -13 <(printf '%s\n' "$EXPECTED_SORTED") <(printf '%s\n' "$PRODUCED_SO") | sed 's/^/  /' >&2
  exit 1
fi
echo "  OK: $(printf '%s\n' "$PRODUCED_SO" | wc -l | tr -d ' ') lib*.so match the symlink-farm names exactly"

# ---------------------------------------------------------------------------
# C5 — every shipped .so must be 16 KB-aligned (each PT_LOAD Align >= 0x4000).
# The build-*.sh LDFLAGS set -Wl,-z,max-page-size=16384; verify it stuck.
# ---------------------------------------------------------------------------
echo ""
echo "---------- [$ABI] C5: 16 KB alignment ----------"
_bad=0
for so in "$JNILIBS_DIR"/*.so; do
  if "$READELF" -l "$so" 2>/dev/null | awk '/LOAD/{print $NF}' | grep -qvE '0x(4000|8000|10000)$'; then
    echo "  NOT 16 KB-aligned: $(basename "$so")" >&2; _bad=1
  fi
done
[ "$_bad" = 0 ] || { echo "ERROR: some shipped .so are not 16 KB-aligned (C5)." >&2; exit 1; }
echo "  OK: all shipped .so are 16 KB-aligned"

# ---------------------------------------------------------------------------
# 7. Stage APK ASSETS (share/cups + share/gutenprint). These are the DATA files
#    cupsd + its filters read at runtime (web templates, docroot, mime, gutenprint
#    xml). The corrected locale-flatten staging (English base, no Cyrillic clobber)
#    already lives in stage.sh / stage-gutenprint.sh and lands under OUT_ROOT; we
#    copy that staged tree into ASSETS_DIR in the layout MainActivity extracts
#    (cups/share/cups, cups/share/doc/cups, gutenprint/share/gutenprint).
# ---------------------------------------------------------------------------
echo ""
echo "---------- [$ABI] staging APK assets into ASSETS_DIR ----------"
rm -rf "$ASSETS_DIR/cups" "$ASSETS_DIR/gutenprint"
mkdir -p "$ASSETS_DIR/cups/share" "$ASSETS_DIR/gutenprint/share"

# cups: share/cups (mime + data + templates) and share/doc/cups (docroot).
cp -a "$CUPS_OUT/share/cups" "$ASSETS_DIR/cups/share/"
mkdir -p "$ASSETS_DIR/cups/share/doc"
cp -a "$CUPS_OUT/share/doc/cups" "$ASSETS_DIR/cups/share/doc/"

# imagetoraster's mime .convs must reach cupsd's DataDir/mime alongside the
# stock mime.types/mime.convs (cupsd rejects image/jpeg without it).
CONVS_SRC="$SCRIPT_DIR/cupsfilters/imagetoraster.convs"
if [ -f "$CONVS_SRC" ]; then
  cp -f "$CONVS_SRC" "$ASSETS_DIR/cups/share/cups/mime/imagetoraster.convs"
fi

# gutenprint: share/gutenprint/5.3/xml (driver data, ~6.6 MB).
cp -a "$GUTENPRINT_OUT/share/gutenprint" "$ASSETS_DIR/gutenprint/share/"

# Assert the English web template is present + not Cyrillic-clobbered (the bug
# the stage.sh locale fix prevents; proven in the APK by the C4 acceptance check).
HDR="$ASSETS_DIR/cups/share/cups/templates/header.tmpl"
if [ ! -f "$HDR" ] || ! grep -q '<!DOCTYPE HTML>' "$HDR"; then
  echo "ERROR: staged web template $HDR missing or not the English base (C4/locale bug)." >&2
  exit 1
fi
echo "  OK: assets staged (cups + gutenprint); English header.tmpl present"

# ---------------------------------------------------------------------------
# 8. Stage LINK INPUTS for CMake: static archives + headers into STAGE_DIR.
# ---------------------------------------------------------------------------
echo ""
echo "---------- [$ABI] staging link inputs into STAGE_DIR ----------"
cp -f "$CUPS_OUT/lib/libcups.a"      "$STAGE_DIR/lib/libcups.a"
cp -f "$CUPS_OUT/lib/libcupsimage.a" "$STAGE_DIR/lib/libcupsimage.a"
rm -rf "$STAGE_DIR/include/cups"
mkdir -p "$STAGE_DIR/include/cups"
cp -a "$CUPS_OUT/include/cups/." "$STAGE_DIR/include/cups/"
[ -f "$STAGE_DIR/lib/libcups.a" ] || { echo "ERROR: libcups.a not staged to STAGE_DIR" >&2; exit 1; }
[ -f "$STAGE_DIR/include/cups/cups.h" ] || { echo "ERROR: cups.h not staged to STAGE_DIR" >&2; exit 1; }
echo "  OK: libcups.a + libcupsimage.a + headers -> STAGE_DIR"

# --- manifest + cache marker -----------------------------------------------
{
  echo "printing_ffi CUPS stack — $ABI (API $MIN_SDK), key $KEY"
  echo "versions: libusb=$LIBUSB_VER jpeg=$JPEG_VER png=$PNG_VER tiff=$TIFF_VER cups=$CUPS_VER cups-filters=$CUPSFILTERS_VER gutenprint=$GUTENPRINT_VER"
  echo "jniLibs:"
  printf '%s\n' "$PRODUCED_SO" | sed 's/^/  /'
} > "$STAGE_DIR/manifest.txt"

touch "$MARKER"
echo ""
echo "==============================================================="
echo " printing_ffi: CUPS stack build complete for $ABI"
echo "   jniLibs: $JNILIBS_DIR ($(printf '%s\n' "$PRODUCED_SO" | wc -l | tr -d ' ') .so)"
echo "   assets : $ASSETS_DIR"
echo "   stage  : $STAGE_DIR (libcups.a for CMake link)"
echo "==============================================================="
