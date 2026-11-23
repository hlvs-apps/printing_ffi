#!/usr/bin/env bash
# Build the on-device CUPS daemon (topology L) and package it as a .deb, FROM
# the app build. The app is the only checkout on the build machine; printing_ffi
# lives in pub-cache, so this runs as a CocoaPods build phase (after build.sh)
# and the resulting .deb is embedded in the app bundle for on-device install via
# any jailbreak package manager (Sileo/Zebra/...).
#
# Self-contained: compiles with xcrun clang, packages with `ar` + `tar` (both on
# macOS) — no dpkg-deb / brew dependency, so it cannot break the app build for a
# missing tool. Runs on macOS/Xcode; NOT on Linux.
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
[[ -f "$RUNTIME/bin/libcupsd.so" ]] || { echo "runtime missing; run tool/ios/build.sh first ($RUNTIME)" >&2; exit 2; }
[[ -f "$STAGE/lib/libcups.a" ]] || { echo "staged libcups missing; run tool/ios/build.sh first" >&2; exit 2; }

# Skip if the .deb is already newer than every input (keeps rebuilds cheap).
newest_input=$(ls -t "$TASK_DIR/fotobox_cupsd.c" "$PLUGIN/src/printing_ffi.c" \
  "$TASK_DIR/control" "$TASK_DIR/postinst" "$TASK_DIR/prerm" \
  "$TASK_DIR/com.fotobox.cupsd.plist" "$TASK_DIR/daemon.entitlements" \
  "$RUNTIME/bin/libcupsd.so" 2>/dev/null | head -1)
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

# --- Lay out the data tree (installed files) ---
DATA="$WORK/data"
mkdir -p "$DATA/$PREFIX_REL/bin" "$DATA/$PREFIX_REL/share" \
         "$DATA/var/jb/Library/LaunchDaemons"
# Runtime (cupsd, filters, Gutenprint backend, data) — already ad-hoc signed with
# the USB/iokit entitlements by build.sh.
cp -R "$RUNTIME/bin/." "$DATA/$PREFIX_REL/bin/"
cp -R "$RUNTIME/share/." "$DATA/$PREFIX_REL/share/"
install -m 0755 "$WORK/fotobox-cupsd" "$DATA/$PREFIX_REL/bin/fotobox-cupsd"
install -m 0644 "$TASK_DIR/com.fotobox.cupsd.plist" \
  "$DATA/var/jb/Library/LaunchDaemons/com.fotobox.cupsd.plist"
chmod -R a+rX "$DATA/$PREFIX_REL"

# --- Assemble the .deb ---
rm -f "$OUT"
if command -v dpkg-deb >/dev/null 2>&1; then
  # Preferred: dpkg-deb produces a canonical package. Control files go under
  # DEBIAN/ in the data tree; --root-owner-group makes installed files root:root.
  mkdir -p "$DATA/DEBIAN"
  install -m 0644 "$TASK_DIR/control" "$DATA/DEBIAN/control"
  install -m 0755 "$TASK_DIR/postinst" "$DATA/DEBIAN/postinst"
  install -m 0755 "$TASK_DIR/prerm" "$DATA/DEBIAN/prerm"
  dpkg-deb -Zxz --root-owner-group --build "$DATA" "$OUT"
else
  # Fallback (no dpkg): assemble the ar(debian-binary, control.tar.gz,
  # data.tar.gz) by hand with tools every macOS has. bsdtar sets root ownership.
  CTRL="$WORK/control"; mkdir -p "$CTRL"
  install -m 0644 "$TASK_DIR/control" "$CTRL/control"
  install -m 0755 "$TASK_DIR/postinst" "$CTRL/postinst"
  install -m 0755 "$TASK_DIR/prerm" "$CTRL/prerm"
  TAROWN=(--uid 0 --gid 0 --uname root --gname wheel)
  ( cd "$CTRL" && tar "${TAROWN[@]}" -czf "$WORK/control.tar.gz" ./control ./postinst ./prerm )
  ( cd "$DATA" && tar "${TAROWN[@]}" -czf "$WORK/data.tar.gz" ./var )
  printf '2.0\n' > "$WORK/debian-binary"
  ( cd "$WORK" && ar -r -c "$OUT" debian-binary control.tar.gz data.tar.gz )
fi
echo "built $OUT ($(wc -c < "$OUT") bytes)"
