#!/usr/bin/env bash
# Build the on-device CUPS daemon (topology L) and package it as a rootless
# .deb, FROM the app build. The app is the only checkout on the build machine;
# printing_ffi lives in pub-cache, so this runs as a CocoaPods build phase
# (after tool/ios/build.sh) and embed_runtime.sh ships the .deb inside the app,
# where the app hands it to the jailbreak package manager (Sileo, Zebra, ...).
#
# Needs dpkg-deb (`brew install dpkg`): it writes the canonical ar/tar layout
# every dpkg frontend reads. Sileo opens a local .deb with the device's own
# `dpkg-deb --field`, so a hand-rolled archive is not an option.
#
# Reuses the CUPS runtime from tool/ios/build.sh (must have run first).
# Output: ios/Resources/com.fotobox.cupsd.deb
set -euo pipefail

TASK_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN="$(cd "$TASK_DIR/../../.." && pwd)"
STAGE="$PLUGIN/ios/.build/arm64"
RUNTIME="$PLUGIN/ios/Resources/CupsRuntime.bundle"
OUT="$PLUGIN/ios/Resources/com.fotobox.cupsd.deb"
PREFIX_REL="var/jb/usr/lib/fotobox-cups"

[[ $(uname -s) == Darwin ]] || { echo 'daemon build requires macOS/Xcode' >&2; exit 2; }
[[ -f "$RUNTIME/bin/libcupsd.so" ]] || { echo "error: CUPS runtime missing; tool/ios/build.sh must run first ($RUNTIME)" >&2; exit 2; }
[[ -f "$STAGE/lib/libcups.a" ]] || { echo "error: staged libcups missing; tool/ios/build.sh must run first" >&2; exit 2; }

# Xcode script phases do not always inherit the login PATH; look where
# Homebrew installs on Apple Silicon and Intel too.
DPKG_DEB="$(PATH="$PATH:/opt/homebrew/bin:/usr/local/bin" command -v dpkg-deb || true)"
if [[ -z "$DPKG_DEB" ]]; then
  echo "error: dpkg-deb not found. Install it once with: brew install dpkg" >&2
  exit 1
fi

# Skip if the .deb is newer than every input (keeps rebuilds cheap).
newest_input=$(ls -t "$0" "$TASK_DIR/fotobox_cupsd.c" "$PLUGIN/src/printing_ffi.c" \
  "$TASK_DIR/control" "$TASK_DIR/postinst" "$TASK_DIR/prerm" "$TASK_DIR/postrm" \
  "$TASK_DIR/com.fotobox.cupsd.plist" "$TASK_DIR/daemon.entitlements" \
  "$RUNTIME/bin/libcupsd.so" 2>/dev/null | head -1 || true)
if [[ -f "$OUT" && -n "$newest_input" && "$OUT" -nt "$newest_input" ]]; then
  echo "daemon .deb up to date: $OUT"; exit 0
fi

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
IOS_MIN=${IPHONEOS_DEPLOYMENT_TARGET:-14.0}
CC="$(xcrun --sdk iphoneos --find clang)"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# --- Compile the daemon (daemon main + the shared plugin C) ---
"$CC" -arch arm64 -isysroot "$SDK" -miphoneos-version-min="$IOS_MIN" \
  -D_DARWIN_C_SOURCE -DPRINTING_FFI_IOS=1 -O2 \
  -I"$STAGE/include" \
  "$TASK_DIR/fotobox_cupsd.c" "$PLUGIN/src/printing_ffi.c" \
  -L"$STAGE/lib" -lcups -lcupsimage -lz -liconv -lresolv \
  -framework Foundation -framework CoreFoundation -framework Security \
  -framework SystemConfiguration \
  -o "$WORK/fotobox-cupsd"
xcrun lipo "$WORK/fotobox-cupsd" -verify_arch arm64

# --- Ad-hoc sign the daemon unsandboxed (honored only on a jailbroken device) ---
codesign --force --sign - --entitlements "$TASK_DIR/daemon.entitlements" "$WORK/fotobox-cupsd"

# --- Lay out the package tree ---
DATA="$WORK/root"
mkdir -p "$DATA/DEBIAN" "$DATA/$PREFIX_REL/bin" "$DATA/$PREFIX_REL/share" \
         "$DATA/var/jb/Library/LaunchDaemons"
# Runtime (cupsd, filters, Gutenprint backend, data) — already ad-hoc signed
# with the USB/IOKit entitlements by build.sh.
cp -R "$RUNTIME/bin/." "$DATA/$PREFIX_REL/bin/"
cp -R "$RUNTIME/share/." "$DATA/$PREFIX_REL/share/"
install -m 0755 "$WORK/fotobox-cupsd" "$DATA/$PREFIX_REL/bin/fotobox-cupsd"
install -m 0644 "$TASK_DIR/com.fotobox.cupsd.plist" \
  "$DATA/var/jb/Library/LaunchDaemons/com.fotobox.cupsd.plist"
chmod -R u+rwX,go+rX,go-w "$DATA/var"
chmod 0755 "$DATA" "$DATA/DEBIAN"

# A fresh version per rebuilt package, so a package manager sees a newer app's
# daemon as an upgrade rather than "already installed".
VERSION="$(sed -n 's/^Version: *//p' "$TASK_DIR/control")+$(date -u +%Y%m%d%H%M%S)"
sed "s/^Version: .*/Version: $VERSION/" "$TASK_DIR/control" > "$DATA/DEBIAN/control"
chmod 0644 "$DATA/DEBIAN/control"
for script in postinst prerm postrm; do
  install -m 0755 "$TASK_DIR/$script" "$DATA/DEBIAN/$script"
done

# --- Assemble: gzip members are readable by every dpkg/APT frontend ---
rm -f "$OUT"
"$DPKG_DEB" -Zgzip --root-owner-group --build "$DATA" "$OUT"

# --- Sanity: the archive dpkg will see on the device ---
"$DPKG_DEB" --field "$OUT" Package Version Architecture
# List once, then search: piping into `grep -q` would SIGPIPE dpkg-deb on a
# large package and fail the build under pipefail.
CONTENTS="$("$DPKG_DEB" --contents "$OUT")"
for want in "./$PREFIX_REL/bin/fotobox-cupsd" "./$PREFIX_REL/bin/libcupsd.so" \
            ./var/jb/Library/LaunchDaemons/com.fotobox.cupsd.plist; do
  grep -qF " $want" <<<"$CONTENTS" || {
    echo "error: $want missing from $OUT" >&2; rm -f "$OUT"; exit 1; }
done
echo "built $OUT ($(wc -c < "$OUT") bytes)"
