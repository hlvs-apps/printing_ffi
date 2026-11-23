#!/usr/bin/env bash
# Build the on-device CUPS daemon (topology L) and package it as a .deb the app
# bundles and hands to a jailbreak package manager (Sileo/Zebra/...) to install.
#
# Runs on macOS/Xcode (or an arm64-iOS cross toolchain). Requires the CUPS
# runtime to have been built already by tool/ios/build.sh (it reuses that
# runtime's binaries + staged libcups), and `dpkg-deb` on PATH (brew install dpkg).
#
# NOT runnable on Linux as written (uses xcrun). Output:
#   ios/Resources/com.fotobox.cupsd.deb
set -euo pipefail

TASK_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN="$(cd "$TASK_DIR/../../.." && pwd)"
STAGE="$PLUGIN/ios/.build/arm64"
RUNTIME="$PLUGIN/ios/Resources/CupsRuntime.bundle"
OUT="$PLUGIN/ios/Resources/com.fotobox.cupsd.deb"
PREFIX_REL="var/jb/usr/lib/fotobox-cups"

[[ $(uname -s) == Darwin ]] || { echo 'daemon build requires macOS/Xcode' >&2; exit 2; }
command -v dpkg-deb >/dev/null || { echo 'dpkg-deb not found (brew install dpkg)' >&2; exit 2; }
[[ -f "$RUNTIME/bin/libcupsd.so" ]] || { echo "runtime missing; run tool/ios/build.sh first ($RUNTIME)" >&2; exit 2; }
[[ -f "$STAGE/lib/libcups.a" ]] || { echo "staged libcups missing; run tool/ios/build.sh first" >&2; exit 2; }

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
IOS_MIN=${IPHONEOS_DEPLOYMENT_TARGET:-14.0}
CC="$(xcrun --sdk iphoneos --find clang)"
CODESIGN="$(xcrun --sdk iphoneos --find codesign 2>/dev/null || echo codesign)"

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
"$CODESIGN" --force --sign - --entitlements "$TASK_DIR/daemon.entitlements" "$WORK/fotobox-cupsd"

# --- Assemble the .deb tree ---
ROOT="$WORK/deb"
mkdir -p "$ROOT/DEBIAN" "$ROOT/$PREFIX_REL/bin" "$ROOT/$PREFIX_REL/share" \
         "$ROOT/var/jb/Library/LaunchDaemons"
cp "$TASK_DIR/control" "$ROOT/DEBIAN/control"
install -m 0755 "$TASK_DIR/postinst" "$ROOT/DEBIAN/postinst"
install -m 0755 "$TASK_DIR/prerm" "$ROOT/DEBIAN/prerm"

# The runtime (cupsd, filters, Gutenprint backend, data) — already ad-hoc signed
# with helper.entitlements (incl. the USB/iokit entitlements) by build.sh.
cp -R "$RUNTIME/bin/." "$ROOT/$PREFIX_REL/bin/"
cp -R "$RUNTIME/share/." "$ROOT/$PREFIX_REL/share/"
install -m 0755 "$WORK/fotobox-cupsd" "$ROOT/$PREFIX_REL/bin/fotobox-cupsd"
cp "$TASK_DIR/com.fotobox.cupsd.plist" "$ROOT/var/jb/Library/LaunchDaemons/"
chmod 0644 "$ROOT/var/jb/Library/LaunchDaemons/com.fotobox.cupsd.plist"

# dpkg metadata owned by root.
find "$ROOT" -type d -exec chmod 0755 {} +
dpkg-deb -Zxz --build "$ROOT" "$OUT"
echo "built $OUT"
