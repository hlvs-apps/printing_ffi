#!/usr/bin/env bash
# Run in the pod target after its native build, before framework signing/embed.
#
# Ships the on-device CUPS daemon package (built by daemon/build_daemon_deb.sh)
# inside the plugin framework, where PrintingFfiPlugin.m finds it and hands it
# to the jailbreak package manager (Sileo, Zebra, ...) via open-in — the only
# install path (no SSH, no repo). The CUPS runtime itself (cupsd, filters, the
# USB backend and their private entitlements) travels ONLY inside that .deb:
# the app is a CUPS client and never runs any of it, so it is not embedded.
set -euo pipefail
DEB_SRC="${PODS_TARGET_SRCROOT:?}/Resources/com.fotobox.cupsd.deb"
DEST_DIR="${TARGET_BUILD_DIR:?}/${UNLOCALIZED_RESOURCES_FOLDER_PATH:?}"
if [[ ! -s "$DEB_SRC" ]]; then
  echo "error: CUPS daemon .deb not found at $DEB_SRC (daemon build phase did not run)" >&2
  exit 1
fi
mkdir -p "$DEST_DIR"
# A previous build embedded the runtime here; drop it so it cannot linger.
rm -rf "$DEST_DIR/CupsRuntime.bundle"
/bin/cp -f "$DEB_SRC" "$DEST_DIR/com.fotobox.cupsd.deb"
echo "Embedded CUPS daemon package at $DEST_DIR/com.fotobox.cupsd.deb"
