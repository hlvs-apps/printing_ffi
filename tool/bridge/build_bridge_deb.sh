#!/usr/bin/env bash
# Build the Fotobox print bridge package (topology B) for THIS machine: run it
# on the box itself (Raspberry Pi OS, Debian, Ubuntu; any architecture), then
# install the result with apt, which pulls in CUPS, Gutenprint and avahi.
#
#   sudo apt install gcc libcups2-dev dpkg-dev
#   tool/bridge/build_bridge_deb.sh
#   sudo apt install ./build/bridge/fotobox-print-bridge_*.deb
#
# The queue manager is the same program as the iOS on-device daemon
# (tool/cups_host/fotobox_cupsd.c), built against the distribution's cupsd.
set -euo pipefail

TASK_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN="$(cd "$TASK_DIR/../.." && pwd)"
OUT_DIR="${1:-$PLUGIN/build/bridge}"

command -v cups-config >/dev/null || { echo 'error: cups-config missing: sudo apt install libcups2-dev' >&2; exit 1; }
command -v dpkg-deb >/dev/null || { echo 'error: dpkg-deb missing: sudo apt install dpkg-dev' >&2; exit 1; }

VERSION="$(sed -n 's/^Version: *//p' "$TASK_DIR/control")"
ARCH="$(dpkg --print-architecture)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# --- The queue manager, against the system libcups ---
# shellcheck disable=SC2046 # cups-config prints several flags
cc -O2 -Wall -Wno-deprecated-declarations -D_GNU_SOURCE -DFOTOBOX_CUPS_SYSTEM \
  $(cups-config --cflags) \
  "$PLUGIN/tool/cups_host/fotobox_cupsd.c" "$PLUGIN/src/printing_ffi.c" \
  $(cups-config --libs) -o "$WORK/fotobox-cupsd"

# --- Package tree ---
ROOT="$WORK/root"
install -d "$ROOT/DEBIAN" "$ROOT/usr/lib/fotobox-print-bridge" "$ROOT/usr/sbin" \
  "$ROOT/usr/share/fotobox-print-bridge" "$ROOT/lib/systemd/system" "$ROOT/etc/avahi/services"
install -m 0755 "$WORK/fotobox-cupsd" "$ROOT/usr/lib/fotobox-print-bridge/fotobox-cupsd"
install -m 0755 "$TASK_DIR/fotobox-print-bridge-pair" "$ROOT/usr/sbin/fotobox-print-bridge-pair"
install -m 0644 "$TASK_DIR/cupsd.conf" "$ROOT/usr/share/fotobox-print-bridge/cupsd.conf"
install -m 0644 "$TASK_DIR/fotobox-print-bridge.service" "$ROOT/lib/systemd/system/fotobox-print-bridge.service"
install -m 0644 "$TASK_DIR/fotobox-print-bridge.avahi.service" "$ROOT/etc/avahi/services/fotobox-print-bridge.service"
echo /etc/avahi/services/fotobox-print-bridge.service > "$ROOT/DEBIAN/conffiles"
sed "s/^Architecture: .*/Architecture: $ARCH/" "$TASK_DIR/control" > "$ROOT/DEBIAN/control"
for script in postinst prerm postrm; do
  install -m 0755 "$TASK_DIR/$script" "$ROOT/DEBIAN/$script"
done
chmod 0644 "$ROOT/DEBIAN/control" "$ROOT/DEBIAN/conffiles"

mkdir -p "$OUT_DIR"
OUT="$OUT_DIR/fotobox-print-bridge_${VERSION}_${ARCH}.deb"
dpkg-deb --root-owner-group --build "$ROOT" "$OUT"
dpkg-deb --field "$OUT" Package Version Architecture
echo "built $OUT"
