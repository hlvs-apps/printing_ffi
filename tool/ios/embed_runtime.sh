#!/usr/bin/env bash
# Run in the pod target after its native build, before framework signing/embed.
set -euo pipefail
SOURCE="${PODS_TARGET_SRCROOT:?}/Resources/CupsRuntime.bundle"
DEST="${TARGET_BUILD_DIR:?}/${UNLOCALIZED_RESOURCES_FOLDER_PATH:?}/CupsRuntime.bundle"
for helper in libcupsd.so libcupsbe_gutenprint53usb.so libcupstool_gutenprint_genppd.so; do
  if [[ ! -s "$SOURCE/bin/$helper" || ! -x "$SOURCE/bin/$helper" ]]; then
    echo "error: CUPS runtime build did not produce executable $SOURCE/bin/$helper" >&2
    exit 1
  fi
done
mkdir -p "$(dirname "$DEST")"
/usr/bin/ditto "$SOURCE" "$DEST"
for helper in libcupsd.so libcupsbe_gutenprint53usb.so libcupstool_gutenprint_genppd.so; do
  [[ -s "$DEST/bin/$helper" && -x "$DEST/bin/$helper" ]] || {
    echo "error: CUPS helper was not embedded: $DEST/bin/$helper" >&2
    exit 1
  }
done
echo "Embedded CUPS runtime at $DEST"

# Embed the on-device CUPS daemon .deb so the app can hand it to a jailbreak
# package manager (Sileo/Zebra) via open-in — the only supported install path
# (no SSH, no manual install). Built by tool/ios/daemon/build_daemon_deb.sh.
DEB_SRC="${PODS_TARGET_SRCROOT:?}/Resources/com.fotobox.cupsd.deb"
DEB_DEST="${TARGET_BUILD_DIR:?}/${UNLOCALIZED_RESOURCES_FOLDER_PATH:?}/com.fotobox.cupsd.deb"
if [[ -s "$DEB_SRC" ]]; then
  /bin/cp -f "$DEB_SRC" "$DEB_DEST"
  echo "Embedded CUPS daemon package at $DEB_DEST"
else
  echo "error: CUPS daemon .deb not found at $DEB_SRC (daemon build phase did not run)" >&2
  exit 1
fi
