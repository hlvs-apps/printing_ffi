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
