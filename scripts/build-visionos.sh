#!/usr/bin/env bash
# Build the Ship of Harkinian engine for visionOS as one static library.
#
# Produces, in the build directory:
#   libSoHEngine.a        soh + libultraship + every dependency, merged with libtool
#   soh.o2r               ROM-free port archive (bundle it as an app resource)
#   gamecontrollerdb.txt  pinned SDL controller mappings (bundle it too)
#   soh/assets/           extractor XMLs used for first-run ROM extraction
# and prints the system frameworks/libraries the app must link.
#
# The app is visionos/SoHVision.xcodeproj; this script never builds it.
# Like configure-visionos.sh it does not run scripts/verify-sources.py.
#
# Usage:
#   scripts/build-visionos.sh              # Simulator -> build-visionos-sim/
#   scripts/build-visionos.sh --device     # device    -> build-visionos/
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/sources/Shipwright"
MODE="${1:---simulator}"

case "$MODE" in
    --simulator)
        BUILD_DIR="$ROOT/build-visionos-sim"
        SDK=xrsimulator
        TRIPLE_SUFFIX=-simulator
        ;;
    --device)
        BUILD_DIR="$ROOT/build-visionos"
        SDK=xros
        TRIPLE_SUFFIX=
        ;;
    *)
        echo "Usage: scripts/build-visionos.sh [--simulator|--device]" >&2
        exit 2
        ;;
esac
DEPLOYMENT_TARGET="${DEPLOYMENT_TARGET:-26.0}"

stage=prepare
started=$SECONDS
trap 'result=$?; printf "[SoH visionOS build] stage=%s result=%s elapsed_seconds=%s\n" "$stage" "$result" "$((SECONDS-started))" >&2' EXIT
log_stage() {
    stage="$1"
    printf '[SoH visionOS build] stage=%s elapsed_seconds=%s\n' "$stage" "$((SECONDS-started))" >&2
}

log_stage configure
"$ROOT/scripts/configure-visionos.sh" "$MODE"

log_stage compile
cmake --build "$BUILD_DIR" --target soh --config Release

log_stage port-archive
# Same pinned inputs as generate-port-archive.sh, written into the build dir.
python3 "$ROOT/scripts/build-port-archive.py" \
    "$SRC/soh/assets/custom" "$SRC/libultraship/src/fast/shaders" "$BUILD_DIR/soh.o2r"

log_stage merge
# Every static library the soh target links, transitively. SDL2main is never
# included: the host app owns main().
LIBS=(
    soh/libsoh.a
    libultraship/src/libultraship.a
    ZAPD/libZAPDLib.a
    OTRExporter/OTRExporter/libOTRExporter.a
    libultraship/libImGui.a
    libultraship/libstb.a
    libultraship/libmonocypher.a
    libultraship/liblibgfxd.a
    _deps/stormlib-build/libstorm.a
    _deps/prism-build/libprism.a
    _deps/sdl2-build/libSDL2.a
    _deps/libzip-build/lib/libzip.a
    _deps/tinyxml2-build/libtinyxml2.a
    _deps/spdlog-build/libspdlog.a
    _deps/png-build/libpng16.a
    _deps/ogg-build/libogg.a
    _deps/vorbis-build/lib/libvorbis.a
    _deps/vorbis-build/lib/libvorbisenc.a
    _deps/vorbis-build/lib/libvorbisfile.a
    _deps/opus-build/libopus.a
    libopusfile.a
)
INPUTS=()
for lib in "${LIBS[@]}"; do
    if [ ! -f "$BUILD_DIR/$lib" ]; then
        echo "Missing static library: $BUILD_DIR/$lib" >&2
        exit 1
    fi
    INPUTS+=("$BUILD_DIR/$lib")
done
# Catch libraries added later that the list above does not know about.
while IFS= read -r lib; do
    rel="${lib#"$BUILD_DIR"/}"
    case " ${LIBS[*]} " in
        *" $rel "*) continue ;;
    esac
    case "$rel" in
        # libpng.a is a link to libpng16.a.
        *SDL2main*|*SDL2_test*|_deps/png-build/libpng.a) ;;
        *) echo "warning: static library not merged: $rel" >&2 ;;
    esac
done < <(find "$BUILD_DIR" -name '*.a' -not -path '*-subbuild/*' -not -name 'libSoHEngine.a' -not -name '*SDL2main*' | sort)

ENGINE="$BUILD_DIR/libSoHEngine.a"
rm -f "$ENGINE"
# Duplicate member names across libraries are expected and harmless.
xcrun libtool -static -no_warning_for_no_symbols -o "$ENGINE" "${INPUTS[@]}" 2> >(grep -v "same member name" >&2)

# System frameworks and libraries required by the merged engine, from the
# CMake link interfaces: libultraship (Foundation, AVFoundation, Metal,
# QuartzCore, CoreAudio, AudioToolbox), SDL2 audio/joystick/haptics/sensor/power
# (GameController, CoreHaptics, CoreMotion, UIKit), soh mod import
# (UniformTypeIdentifiers) and libzip/libpng (libz, libbz2). The link check
# below fails if this list is incomplete.
FRAMEWORKS=(
    Foundation
    AVFoundation
    AudioToolbox
    CoreAudio
    CoreHaptics
    CoreMotion
    GameController
    Metal
    QuartzCore
    UIKit
    UniformTypeIdentifiers
)
SYSLIBS=(z bz2 c++)

log_stage link-check
# Prove that the list above is complete: link a throwaway executable that only
# references the engine entry point and the host C API.
PROBE_DIR="$BUILD_DIR/link-probe"
mkdir -p "$PROBE_DIR"
cat > "$PROBE_DIR/probe.c" <<'EOF'
#include "fast/backends/gfx_host.h"
int SoHEngine_Main(int argc, char** argv);
int main(int argc, char** argv) {
    HP_SetViewSize(1920, 1080);
    HP_SetActive(1);
    HP_SetPresenter(0);
    HP_SetEyeCount(1);
    HP_SetScreenGeometry(2.0f, 3.0f);
    return SoHEngine_Main(argc, argv);
}
EOF
LINK_ARGS=()
for framework in "${FRAMEWORKS[@]}"; do LINK_ARGS+=(-framework "$framework"); done
for syslib in "${SYSLIBS[@]}"; do LINK_ARGS+=("-l$syslib"); done
xcrun --sdk "$SDK" clang -target "arm64-apple-xros${DEPLOYMENT_TARGET}${TRIPLE_SUFFIX}" \
    -I "$SRC/libultraship/include" \
    "$PROBE_DIR/probe.c" "$ENGINE" "${LINK_ARGS[@]}" \
    -Wl,-dead_strip -o "$PROBE_DIR/probe"

log_stage complete
echo
echo "Engine:   $ENGINE ($(du -h "$ENGINE" | cut -f1))"
echo "Archive:  $BUILD_DIR/soh.o2r"
echo "Mappings: $BUILD_DIR/gamecontrollerdb.txt"
echo "Assets:   $BUILD_DIR/soh/assets"
echo "Headers:  $SRC/libultraship/include/fast/backends/gfx_host.h"
echo "Entry:    int SoHEngine_Main(int argc, char** argv)"
echo
echo "Link the app with:"
printf '  -framework %s\n' "${FRAMEWORKS[@]}"
printf '  -l%s\n' "${SYSLIBS[@]}"
