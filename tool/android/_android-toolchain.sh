#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# _android-toolchain.sh — sourced by the build-*.sh cross-compile scripts.
#
# Resolves the NDK host toolchain dir + a parallel-jobs count in a way that
# works on macOS AND Linux/WSL2. Replaces the previously hard-coded
# `.../prebuilt/darwin-x86_64` + `$(sysctl -n hw.ncpu)`, which broke every
# non-macOS host (the plan requires cross-compiling from any platform; on
# Windows that means WSL2 — see docs/android-plugin-reusability-plan.md, D5/C1).
#
# Requires NDK to be set before sourcing. Sets + exports: TOOLCHAIN, JOBS
# (HOST_TAG is informational).
# ---------------------------------------------------------------------------
: "${NDK:?_android-toolchain.sh: NDK must be set before sourcing}"

# Native Windows can't run autotools/patchelf. Fail fast, point at WSL2.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN*)
    echo "ERROR: the Android CUPS cross-compile needs a POSIX host (autotools + patchelf)." >&2
    echo "       On Windows, run the Android build under WSL2." >&2
    exit 1
    ;;
esac

# The NDK ships exactly one prebuilt toolchain dir for the host. Pick whichever
# exists so the same script runs on an Intel/ARM Mac and on Linux/WSL2.
_ndk_prebuilt="$NDK/toolchains/llvm/prebuilt"
TOOLCHAIN=""
HOST_TAG=""
for _tag in \
  "$(uname -s | tr '[:upper:]' '[:lower:]')-x86_64" \
  darwin-x86_64 darwin-arm64 linux-x86_64 linux-arm64; do
  if [ -d "$_ndk_prebuilt/$_tag" ]; then
    TOOLCHAIN="$_ndk_prebuilt/$_tag"
    HOST_TAG="$_tag"
    break
  fi
done
if [ -z "$TOOLCHAIN" ]; then
  echo "ERROR: no NDK host toolchain under $_ndk_prebuilt (looked for *-x86_64 / *-arm64)." >&2
  echo "       Is NDK=$NDK correct? Expected NDK r27 (27.0.12077973)." >&2
  exit 1
fi
export TOOLCHAIN HOST_TAG

# Parallel make jobs: nproc on Linux/WSL2, sysctl on macOS, 4 as a safe default.
JOBS="${JOBS:-$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)}"
export JOBS
