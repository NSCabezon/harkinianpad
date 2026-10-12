#!/usr/bin/env bash
# Generate the default Metal shader list bundled with the visionOS app.
#
# The engine records every shader/pipeline it builds in Documents/shader-cache.txt and,
# on later launches, compiles them on background threads before the game needs them.
# The seed gives a fresh install the same head start: build-visionos.sh copies it to
# <build>/soh/assets/, which the app's Copy Engine Resources phase bundles as
# assets/shader-cache-seed.txt.
#
# Usage: play the title screen / file select / first scenes in the simulator, then
#   scripts/generate-shader-seed.sh [SIMULATOR_UDID | path/to/shader-cache.txt]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/assets/visionos/shader-cache-seed.txt"
SRC="${1:-booted}"

if [ -f "$SRC" ]; then
    CACHE="$SRC"
else
    DATA="$(xcrun simctl get_app_container "$SRC" com.nscabezon.sohvision data)"
    CACHE="$DATA/Documents/shader-cache.txt"
fi
if [ ! -f "$CACHE" ]; then
    echo "No shader cache at $CACHE (run the app with this build first)" >&2
    exit 1
fi

mkdir -p "$(dirname "$OUT")"
# Keep the header and the first occurrence of each line, in first-use order.
awk '!seen[$0]++' "$CACHE" > "$OUT"
echo "Wrote $(grep -vc '^#' "$OUT") entries to $OUT"
