#!/usr/bin/env bash
# Integration test of the print bridge package in a throwaway container.
#   tool/bridge/test/run_bridge_test.sh [image]   (default debian:bookworm)
set -euo pipefail
PLUGIN="$(cd "$(dirname "$0")/../../.." && pwd)"
IMAGE="${1:-debian:bookworm}"
exec docker run --rm --network host -v "$PLUGIN:/src:ro" "$IMAGE" \
  bash /src/tool/bridge/test/in_container.sh
