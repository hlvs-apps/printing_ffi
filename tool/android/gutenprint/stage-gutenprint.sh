#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# stage-gutenprint.sh
# Copy the built Gutenprint cross artifacts into out/arm64-gutenprint/ and
# verify they are AArch64. Invoked by build-gutenprint.sh (inherits env:
# OUT_DIR, SRC_DIR, GP_VERSION, READELF, STAGED_CUPS).
# ---------------------------------------------------------------------------
set -euo pipefail

: "${OUT_DIR:?}"; : "${SRC_DIR:?}"; : "${GP_VERSION:?}"; : "${READELF:?}"

REL="5.3"   # GUTENPRINT_RELEASE_VERSION (major.minor) for binary suffixes

mkdir -p "$OUT_DIR/lib" "$OUT_DIR/bin" "$OUT_DIR/cups/filter" "$OUT_DIR/cups/backend" \
         "$OUT_DIR/share/gutenprint" "$OUT_DIR/include"

copy_if() {  # copy_if <src> <dstdir>  (skips missing, follows libtool wrappers)
  local src="$1" dst="$2"
  if [ -f "$src" ]; then
    cp -f "$src" "$dst/"
    echo "    staged: $(basename "$src") -> $dst/"
  else
    echo "    (absent, skipped): $src"
  fi
}

echo "==> Staging libraries"
# libtool puts the real static archive under .libs/
copy_if "$SRC_DIR/src/main/.libs/libgutenprint.a" "$OUT_DIR/lib"
# (if a shared lib slipped through)
copy_if "$SRC_DIR/src/main/.libs/libgutenprint.so" "$OUT_DIR/lib" || true

echo "==> Staging CUPS filter + command filters"
copy_if "$SRC_DIR/src/cups/rastertogutenprint.$REL" "$OUT_DIR/cups/filter"
copy_if "$SRC_DIR/src/cups/commandtoepson"          "$OUT_DIR/cups/filter"
copy_if "$SRC_DIR/src/cups/commandtocanon"          "$OUT_DIR/cups/filter"
copy_if "$SRC_DIR/src/cups/commandtodyesub"         "$OUT_DIR/cups/filter"

echo "==> Staging CUPS driver helpers (PPD generator etc.)"
copy_if "$SRC_DIR/src/cups/cups-genppd.$REL"        "$OUT_DIR/bin"
copy_if "$SRC_DIR/src/cups/gutenprint.$REL"         "$OUT_DIR/bin"   # cups 1.2 driver interface
copy_if "$SRC_DIR/src/cups/cups-calibrate"          "$OUT_DIR/bin"

echo "==> Staging DNP / dye-sub USB backend (only present if libusb was found)"
# The build name is backend_gutenprint; the Makefile install-hook renames it to
# gutenprint<major><minor>+usb (i.e. gutenprint53+usb) and chmod 700. Stage under
# BOTH names: backend_gutenprint (raw) and the on-device gutenprint53+usb name.
BE_SRC=""
if [ -f "$SRC_DIR/src/cups/.libs/backend_gutenprint" ]; then
  BE_SRC="$SRC_DIR/src/cups/.libs/backend_gutenprint"   # libtool: real ELF under .libs
elif [ -f "$SRC_DIR/src/cups/backend_gutenprint" ]; then
  BE_SRC="$SRC_DIR/src/cups/backend_gutenprint"
fi
if [ -n "$BE_SRC" ]; then
  cp -f "$BE_SRC" "$OUT_DIR/cups/backend/backend_gutenprint"
  cp -f "$BE_SRC" "$OUT_DIR/cups/backend/gutenprint${REL/./}+usb"   # gutenprint53+usb
  echo "    staged: backend_gutenprint + gutenprint${REL/./}+usb -> $OUT_DIR/cups/backend/"
else
  echo "    (absent, skipped): backend_gutenprint (libusb not found at configure time?)"
fi

echo "==> Staging driver DATA (share/gutenprint XML)"
# The XML driver data the library reads at runtime. Source-of-truth is src/xml/.
if [ -d "$SRC_DIR/src/xml" ]; then
  # Mirror the on-device layout: share/gutenprint/<rel>/xml/...
  mkdir -p "$OUT_DIR/share/gutenprint/$REL/xml"
  # Copy the actual xml data trees (printers, papers, dither, escp2), excluding
  # build scaffolding (*.am, *.in, *.c, Makefile*, generated tmp headers) AND any
  # autotools/staging pollution (.deps, .libs, and a stray `tool`/`out` tree a
  # prior mis-run could leave under src/xml — prune it so the copy can't recurse
  # into a previously-staged OUT_DIR and blow up into thousands of files).
  ( cd "$SRC_DIR/src/xml"
    find . \( -name .deps -o -name .libs -o -name tool -o -name out \) -prune -o \
      -type d -print \
      -exec sh -c 'mkdir -p "$0/$1"' "$OUT_DIR/share/gutenprint/$REL/xml" {} \;
    find . \( -name .deps -o -name .libs -o -name tool -o -name out \) -prune -o \
      -type f \( -name '*.xml' -o -name 'xml-stamp' \) -print \
      -exec sh -c 'cp -f "$1" "$0/$2"' "$OUT_DIR/share/gutenprint/$REL/xml" {} {} \;
  )
  echo "    staged: src/xml/*.xml -> share/gutenprint/$REL/xml/"
fi

echo "==> Staging public headers (for later FFI/link reference)"
if [ -d "$SRC_DIR/include/gutenprint" ]; then
  mkdir -p "$OUT_DIR/include/gutenprint"
  # Headers are a mix of .h (committed) and .h built from .h.in; copy both.
  find "$SRC_DIR/include/gutenprint" -maxdepth 1 -name '*.h' \
    -exec cp -f {} "$OUT_DIR/include/gutenprint/" \;
  echo "    staged: include/gutenprint/*.h"
fi

echo ""
echo "==> AArch64 verification"
verify() {
  local f="$1"
  [ -f "$f" ] || return 0
  echo "--- $f"
  file "$f" 2>/dev/null | sed 's/^/    file: /' || true
  "$READELF" -h "$f" 2>/dev/null | grep -E 'Class|Type|Machine' | sed 's/^/    /' || true
}
for f in "$OUT_DIR"/cups/filter/* "$OUT_DIR"/bin/* "$OUT_DIR"/cups/backend/*; do
  verify "$f"
done
echo "--- $OUT_DIR/lib/libgutenprint.a (static archive — check a member)"
if [ -f "$OUT_DIR/lib/libgutenprint.a" ]; then
  file "$OUT_DIR/lib/libgutenprint.a" | sed 's/^/    file: /'
  # extract first object and check its arch
  tmpd="$(mktemp -d)"
  ( cd "$tmpd" && "${AR:-llvm-ar}" x "$OUT_DIR/lib/libgutenprint.a" 2>/dev/null || true
    first_o="$(ls *.o 2>/dev/null | head -1)"
    if [ -n "$first_o" ]; then
      "$READELF" -h "$first_o" 2>/dev/null | grep -E 'Class|Machine' | sed 's/^/    member '"$first_o"': /'
    fi )
  rm -rf "$tmpd"
fi

echo ""
echo "==> Dynamic deps (NEEDED) of staged executables"
for f in "$OUT_DIR"/cups/filter/* "$OUT_DIR"/bin/* "$OUT_DIR"/cups/backend/*; do
  [ -f "$f" ] || continue
  echo "--- $(basename "$f")"
  "$READELF" -d "$f" 2>/dev/null | grep -i NEEDED | sed 's/^/    /' || echo "    (no dynamic section / static)"
done

echo ""
echo "==> DNP backend content + libusb link verification"
BE="$OUT_DIR/cups/backend/backend_gutenprint"
if [ -f "$BE" ]; then
  echo "--- DNP support present? (strings | grep -i dnp) ---"
  strings "$BE" 2>/dev/null | grep -i 'dnp' | head -8 | sed 's/^/    /' || echo "    (no dnp strings found!)"
  echo "--- dnpds40 symbols? (nm) ---"
  "${NM:-llvm-nm}" "$BE" 2>/dev/null | grep -iE 'dnpds40|dnp_' | head -8 | sed 's/^/    /' || echo "    (no dnp symbols)"
  echo "--- libusb linkage (static-embedded or NEEDED) ---"
  if "$READELF" -d "$BE" 2>/dev/null | grep -qi 'libusb'; then
    "$READELF" -d "$BE" 2>/dev/null | grep -i 'libusb' | sed 's/^/    NEEDED: /'
  else
    echo "    (no NEEDED libusb-1.0.so -> libusb is STATICALLY embedded)"
    echo "    libusb symbols embedded (nm | grep -i libusb_init):"
    "${NM:-llvm-nm}" "$BE" 2>/dev/null | grep -iE ' [tT] libusb_(init|open|get_device_list|wrap_sys_device|set_option)' | head | sed 's/^/    /' || true
  fi
  echo "--- PRINTING_FFI fd-handoff patch present? (patch 0002) ---"
  if strings "$BE" 2>/dev/null | grep -q 'PRINTING_FFI_USB_FD'; then
    strings "$BE" 2>/dev/null | grep -iE 'PRINTING_FFI_USB_FD(_SOCK)?$' | sort -u | sed 's/^/    env: /'
    echo "    -> fd-handoff (SCM_RIGHTS socket + raw-int fallback) compiled in"
  else
    echo "    !! PRINTING_FFI_USB_FD NOT found — fd-handoff patch 0002 missing!"
  fi
else
  echo "    backend_gutenprint NOT staged (DNP backend was not built this pass)."
fi

echo ""
echo "==> Staged tree size"
du -sh "$OUT_DIR" 2>/dev/null | sed 's/^/    /'
du -sh "$OUT_DIR/share/gutenprint" 2>/dev/null | sed 's/^/    share: /'

echo "==> stage-gutenprint.sh done"
