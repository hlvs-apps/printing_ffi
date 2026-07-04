#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# stage.sh — copy the freshly built CUPS artifacts out of the build tree into
# tool/android/out/arm64/ in the on-device runtime layout.
# Called by build-cups.sh (which exports CUPS_LINK), but can be run standalone
# after a build:  CUPS_LINK=static tool/android/stage.sh
#
# Link mode (CUPS_LINK, default static):
#   static -> stages the static archives libcups.a / libcupsimage.a + the cups
#             public headers (the FFI C #includes <cups/cups.h> and links the
#             .a). Executables are self-contained, so NO libcups.so* is staged.
#   shared -> stages libcups.so.2 (+ libcupsimage.so.2) and the unversioned
#             dev symlinks, the original spike layout.
# ---------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# OUT_ROOT / STAGE_BUILD_DIR are env-overridable (C2): build-cups.sh passes the
# same (possibly redirected) roots so a standalone run and an orchestrated run
# stage from/to the same trees. Defaults keep standalone runs unchanged.
OUT_ROOT="${OUT_ROOT:-$SCRIPT_DIR/out}"
BUILD_DIR="${STAGE_BUILD_DIR:-$SCRIPT_DIR/build}"
OUT_DIR="$OUT_ROOT/arm64"
CUPS_VERSION="2.4.19"
SRC_DIR="$BUILD_DIR/cups-${CUPS_VERSION}"
CUPS_LINK="${CUPS_LINK:-static}"

echo "==> stage.sh link mode: $CUPS_LINK"

mkdir -p \
  "$OUT_DIR/lib/cups/backend" \
  "$OUT_DIR/lib/cups/daemon" \
  "$OUT_DIR/lib/cups/filter" \
  "$OUT_DIR/lib/cups/cgi-bin" \
  "$OUT_DIR/include/cups" \
  "$OUT_DIR/sbin" \
  "$OUT_DIR/bin" \
  "$OUT_DIR/share/cups/mime" \
  "$OUT_DIR/share/cups/banners" \
  "$OUT_DIR/share/cups/templates" \
  "$OUT_DIR/share/doc/cups" \
  "$OUT_DIR/etc/cups"

copy() {  # copy SRC DEST  (skip if SRC missing, log either way)
  local src="$1" dest="$2"
  if [ -e "$src" ]; then
    cp -a "$src" "$dest"
    echo "  staged: $(basename "$src") -> ${dest#$OUT_DIR/}"
  else
    echo "  MISSING (not built): $src"
  fi
}

# ---------------------------------------------------------------------------
# libcups: static archives (.a) in static mode, shared objects in shared mode.
# ---------------------------------------------------------------------------
if [ "$CUPS_LINK" = "static" ]; then
  echo "==> Staging libcups static archives (.a) + headers"
  # In --disable-shared builds CUPS names the lib target libcups.a / libcupsimage.a.
  # Remove any stale .so left from a previous shared build so the tree is clean.
  rm -f "$OUT_DIR/lib/"libcups*.so* 2>/dev/null || true
  copy "$SRC_DIR/cups/libcups.a"      "$OUT_DIR/lib/"
  copy "$SRC_DIR/cups/libcupsimage.a" "$OUT_DIR/lib/"

  echo "==> Staging cups public headers (for FFI #include <cups/cups.h>)"
  # The FFI C layer compiles against these and links the static .a above.
  for h in "$SRC_DIR/cups/"*.h; do
    [ -e "$h" ] || continue
    copy "$h" "$OUT_DIR/include/cups/"
  done
else
  echo "==> Staging libcups shared objects (.so)"
  # CUPS 2.4.x does NOT use libtool; the real .so (libcups.so.2) and the
  # libcups.so symlink live directly in cups/, not under .libs/.
  rm -f "$OUT_DIR/lib/"libcups*.a 2>/dev/null || true
  copy "$SRC_DIR/cups/libcups.so.2" "$OUT_DIR/lib/"
  ( cd "$OUT_DIR/lib" && ln -sf libcups.so.2 libcups.so )
  echo "  linked: libcups.so -> libcups.so.2"
  copy "$SRC_DIR/cups/libcupsimage.so.2" "$OUT_DIR/lib/"
  [ -e "$SRC_DIR/cups/libcupsimage.so.2" ] && ( cd "$OUT_DIR/lib" && ln -sf libcupsimage.so.2 libcupsimage.so )

  # Headers are useful in both modes.
  echo "==> Staging cups public headers"
  for h in "$SRC_DIR/cups/"*.h; do
    [ -e "$h" ] || continue
    copy "$h" "$OUT_DIR/include/cups/"
  done
fi

echo "==> Staging cupsd scheduler"
copy "$SRC_DIR/scheduler/cupsd" "$OUT_DIR/sbin/"

echo "==> Staging cupsd helper daemons"
# These are execd by cupsd at runtime.
for d in cups-deviced cups-driverd cups-exec cups-lpd cupsfilter; do
  copy "$SRC_DIR/scheduler/$d" "$OUT_DIR/lib/cups/daemon/"
done

echo "==> Staging backends (socket, ipp, lpd, + others if built)"
for b in socket ipp lpd http https snmp dnssd usb; do
  copy "$SRC_DIR/backend/$b" "$OUT_DIR/lib/cups/backend/"
done

echo "==> Staging filters (built CUPS-core filters)"
# NOTE (spike 2b): stage.sh previously skipped these; gziptoany in particular
# is the universal raw/gz pass-through every queue uses.
for f in gziptoany commandtops pstops rastertoepson rastertohp rastertolabel rastertopwg; do
  copy "$SRC_DIR/filter/$f" "$OUT_DIR/lib/cups/filter/"
done

echo "==> Staging CGI programs (web interface — served by cupsd from ServerBin/cgi-bin)"
# cupsd exec's these as <ServerBin>/cgi-bin/<name>.cgi (scheduler/client.c). They
# are self-contained PIE (static libcups + libcupscgi, bionic-only). On device the
# symlink farm maps cgi-bin/<name>.cgi -> nativeLibraryDir/libcupscgi_<name>.so.
for c in admin printers jobs classes help; do
  copy "$SRC_DIR/cgi-bin/$c.cgi" "$OUT_DIR/lib/cups/cgi-bin/"
done

echo "==> Staging web templates (found by CGIs at \$CUPS_DATADIR/templates)"
# cgiGetTemplateDir() reads CUPS_DATADIR (cupsd sets it to DataDir) + /templates.
# Copy every *.tmpl plus the localized subdirs (da/de/es/fr/ja/pt_BR/ru).
if [ -d "$SRC_DIR/templates" ]; then
  # top-level .tmpl files
  for t in "$SRC_DIR/templates/"*.tmpl; do
    [ -e "$t" ] || continue
    cp -a "$t" "$OUT_DIR/share/cups/templates/"
  done
  # localized subdirs -> keep each as templates/<locale>/ (English stays the base).
  # NB: the glob yields a trailing slash ("…/ru/"), and BSD/macOS `cp -a src/ dest/`
  # copies the *contents* of src into dest — that would splat every locale's *.tmpl
  # straight into the base dir, and the last one (ru) would clobber the English base
  # (the "web UI is Russian" bug). Strip the trailing slash with ${d%/} and remove any
  # stale target first so cp creates a real templates/<locale>/ subdir instead.
  for d in "$SRC_DIR/templates/"*/; do
    [ -d "$d" ] || continue
    rm -rf "$OUT_DIR/share/cups/templates/$(basename "$d")"
    cp -a "${d%/}" "$OUT_DIR/share/cups/templates/"
  done
  echo "  staged: templates/*.tmpl (+ locale dirs) -> share/cups/templates/"
else
  echo "  MISSING (not built): $SRC_DIR/templates"
fi

echo "==> Staging web DocumentRoot (static docroot: index.html, css, images, help)"
# cupsd serves static files from DocumentRoot; CGIs reference /cups.css, /images/...
# We stage the built doc/ tree; on device DocumentRoot points at the extracted copy.
# Drop the *.php/test.cgi dev stubs (no PHP/CGI-test on device).
if [ -d "$SRC_DIR/doc" ]; then
  ( cd "$SRC_DIR/doc" && find . \( -name '*.php' -o -name 'test.cgi' -o -name 'Makefile' -o -name '*.in' \) -prune -o -type f -print ) | while read -r rel; do
    rel="${rel#./}"
    mkdir -p "$OUT_DIR/share/doc/cups/$(dirname "$rel")"
    cp -a "$SRC_DIR/doc/$rel" "$OUT_DIR/share/doc/cups/$rel"
  done
  echo "  staged: doc/ -> share/doc/cups/"
else
  echo "  MISSING (not built): $SRC_DIR/doc"
fi

echo "==> Staging client tools (lp, lpr, lpstat, lpadmin, etc.)"
for t in lp lpr lpstat lpadmin lpoptions cancel lpq lprm lpc accept reject \
         cupsenable cupsdisable cupsaccept cupsreject; do
  for sub in systemv berkeley; do
    [ -e "$SRC_DIR/$sub/$t" ] && copy "$SRC_DIR/$sub/$t" "$OUT_DIR/bin/" && break
  done
done

echo "==> Staging data files needed to boot"
copy "$SRC_DIR/conf/mime.types"  "$OUT_DIR/share/cups/mime/"
copy "$SRC_DIR/conf/mime.convs"  "$OUT_DIR/share/cups/mime/"
copy "$SRC_DIR/conf/cupsd.conf"  "$OUT_DIR/etc/cups/cupsd.conf.default" 2>/dev/null || true
# cups data dir (charsets, etc.)
if [ -d "$SRC_DIR/data" ]; then
  cp -a "$SRC_DIR/data" "$OUT_DIR/share/cups/" 2>/dev/null || true
  echo "  staged: data/ -> share/cups/data/"
fi

echo "==> Staged tree:"
( cd "$OUT_DIR" && find . -type f -o -type l | sort )
