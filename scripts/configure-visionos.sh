#!/usr/bin/env bash
# Configure the Ship of Harkinian engine for visionOS (static libraries only).
#
# The app itself is the versioned Xcode project visionos/SoHVision.xcodeproj;
# CMake only builds the engine that scripts/build-visionos.sh merges into
# libSoHEngine.a. See docs/visionos-design.md.
#
# Unlike configure-ios.sh this does not run scripts/verify-sources.py: the
# visionOS port edits the sources. Strict verification is for releases.
#
# Requires: macOS, Xcode with the visionOS SDK, CMake >= 3.28, Ninja (optional).
#
# Usage:
#   scripts/configure-visionos.sh              # visionOS Simulator -> build-visionos-sim/
#   scripts/configure-visionos.sh --device     # visionOS device    -> build-visionos/
#   GENERATOR=Xcode scripts/configure-visionos.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/sources/Shipwright"
DEPLOYMENT_TARGET="${DEPLOYMENT_TARGET:-26.0}"

case "${1:---simulator}" in
    --simulator)
        SDK=xrsimulator
        BUILD_DIR="$ROOT/build-visionos-sim"
        ;;
    --device)
        SDK=xros
        BUILD_DIR="$ROOT/build-visionos"
        ;;
    *)
        echo "Usage: scripts/configure-visionos.sh [--simulator|--device]" >&2
        exit 2
        ;;
esac

if [ ! -d "$SRC" ]; then
    echo "sources/Shipwright not found — run scripts/clone-sources.sh first." >&2
    exit 1
fi

if [ -z "${GENERATOR:-}" ]; then
    if command -v ninja >/dev/null 2>&1; then
        GENERATOR=Ninja
    else
        GENERATOR=Xcode
    fi
fi

# Every dependency is fetched for xros; never let find_package/find_library
# pick up host (macOS) packages from Homebrew.
cmake -Wno-unused-cli \
    -S "$SRC" -B "$BUILD_DIR" \
    -G "$GENERATOR" \
    -DCMAKE_SYSTEM_NAME=visionOS \
    -DCMAKE_OSX_SYSROOT="$SDK" \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
    -DCMAKE_BUILD_TYPE:STRING=Release \
    -DCMAKE_IGNORE_PREFIX_PATH="/opt/homebrew;/usr/local" \
    -DENABLE_SCRIPTING=OFF

echo
echo "Configured: $BUILD_DIR ($SDK, $GENERATOR)"
echo "Build the engine with: scripts/build-visionos.sh ${1:---simulator}"
