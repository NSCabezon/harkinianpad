# visionOS port — design

Goal: Ship of Harkinian running natively on Apple Vision Pro, DualSense (any
extended gamepad) only, later with per-eye stereo rendering. Personal use only.

Prefixes: `SW=sources/Shipwright`, `LUS=$SW/libultraship`, `SOH=$SW/soh`.

## Decisions

- **The app is a versioned Xcode project**: `visionos/SoHVision.xcodeproj`
  (synchronized folder `visionos/SoHVision/`, no generators). It links the engine
  as one static library built by CMake: `libSoHEngine.a` (SoH + LUS + deps,
  merged with `libtool -static`), plus `soh.o2r` as a resource.
- **SDL2 without video**: `-DSDL_VIDEO=OFF -DSDL_RENDER=OFF -DSDL_MISC=OFF`.
  SDL only provides audio, joystick/gamecontroller and the event queue.
  `SDL_SetMainReady()` must run before any `SDL_Init` (`os.cpp:27` exits otherwise).
  No `SDL2main`: the Swift app owns `main`.
- **New LUS window backend `FAST3D_HOST_METAL`** (`gfx_host.cpp`) replaces
  `gfx_sdl2.cpp` on visionOS. The host app supplies device, size, active state
  and a presenter callback through a small C API (`gfx_host.h`).
- **Offscreen framebuffer 0**: `gfx_metal` renders into its own texture; the
  presenter callback gets `(MTLTexture*, MTLCommandBuffer*, eye)` and encodes the
  presentation (phase 1: blit to the layer's drawable). Reasons: decouples the game
  thread from the layer (nil/zero-size drawables), EndFrame readback needs a
  non-framebufferOnly texture, and stereo only swaps the presenter and runs
  `Interpreter::Run` twice in `DrawAndRunGraphicsCommands` (`Fast3dWindow.cpp:210-233`).
- **Game thread**: SoH's loop blocks (`graph.c:482`), so it runs on a dedicated
  pthread (8 MB stack, userInteractive QoS) calling `SDL_SetMainReady(); SDL_main()`,
  each frame wrapped in an autorelease pool. Inactive scene → `HandleEvents`
  blocks on a condvar. Pacing via `SyncFramerateWithTime`, target 90 fps.
- **ImGui**: own platform layer for `FAST3D_HOST_METAL` in `Fast3dGui.cpp`
  (`imgui_impl_sdl2` needs SDL video). Sets DisplaySize/scale/DeltaTime and ports
  `ImGui_ImplSDL2_UpdateGamepads` over `SDL_GameController`. Renderer stays
  `imgui_impl_metal`. `NavEnableGamepad` is already on.
- **Controllers**: unchanged LUS ControlDeck over SDL gamecontroller (SDL uses
  GCController on Apple). The SwiftUI view must use
  `.handlesGameControllerEvents(matching: .gamepad)` (lesson from AlyxAVP).

## Work packages

WP0 (contract) first, then WP1–WP6 in parallel on disjoint files.

| WP | Files | Done when |
|---|---|---|
| 0 Contract | new `LUS/include/fast/backends/gfx_host.h` (C API: `HP_SetPresenter`, `HP_SetViewSize`, `HP_SetActive`, presenter struct `{ctx, present(ctx, MTLTexture*, MTLCommandBuffer*, eye)}`); `FAST3D_HOST_METAL` in `Fast3dWindow.h` | header compiles |
| 1 Build | CMake sites listed below, new `LUS/cmake/dependencies/visionos.cmake`, `scripts/configure-visionos.sh`, `scripts/build-visionos.sh` (produces `libSoHEngine.a` + `soh.o2r`) | configures and builds the engine for xrsimulator; iOS build unchanged |
| 2 Backend | new `LUS/src/fast/backends/gfx_host.cpp`; `Fast3dWindow.cpp:34-39,150-176,211-222` | compiles; every method stubbed or driven by host state |
| 3 Metal | `gfx_metal.h/.cpp`: `MetalInitHost(device)`, size provider, offscreen fb0, presenter called before `commit` (`:623`); nil-drawable guard (`:701`) | iOS SDL path intact |
| 4 ImGui | `Fast3dGui.cpp/.h`, `Gui.cpp:81-92` | menu navigable with a gamepad |
| 5 SoH | `SOH/src/code/main.c:46-62`, touch-controls stub, `OTRGlobals.cpp`, `SohMenuSettings.cpp`, `bootcommands.c` | compiles with `__VISIONOS__` |
| 6 Host | `visionos/SoHVision/*` (Swift app, Metal view, `HPVisionHost.mm`, bridging header) | boots in the visionOS simulator and renders |

CMake sites that test for iOS and must accept visionOS:
`SW/CMakeLists.txt:3,194,214`; `LUS/CMakeLists.txt:14,25,62,79-81`;
`LUS/src/CMakeLists.txt:58,113,156,176`; `LUS/src/fast/CMakeLists.txt:34-40`
(exclude `backends/gfx_sdl2\.cpp$`); `LUS/src/ship/CMakeLists.txt:62,97`;
`SOH/CMakeLists.txt:3,13,144,169,268,333,406,527,633,660,763`;
`SW/ZAPDTR/ZAPD/CMakeLists.txt:378,407`. Remove `SDL2::SDL2main`
(`ios.cmake:~111`, `SOH/CMakeLists.txt:770`).

Stage 1 notes (WP0/WP1/WP2 stubs, done):

- Build: `scripts/build-visionos.sh [--simulator|--device]` (Ninja, native CMake
  `CMAKE_SYSTEM_NAME=visionOS`; no `verify-sources.py`) → `build-visionos-sim/`
  with `libSoHEngine.a`, `soh.o2r`, `gamecontrollerdb.txt`, `soh/assets/`. It
  link-checks the merged library and prints the frameworks the app must link.
- Entry point: `int SoHEngine_Main(int argc, char** argv)` (`SOH/src/code/main.c`)
  calls `SDL_SetMainReady()` and then SoH's `SDL_main`. The host calls it on the
  game thread. The library contains no `main` and no SDL2main.
- Defines: visionOS keeps `__IOS__` (Documents path, SDL audio, mobile ImGui,
  extractor, no networking) and adds `__VISIONOS__` only where it differs
  (backend choice, `gfx_host.cpp`, entry point). Touch controls are a no-op C
  stub (`SOH/visionos/HarkinianPadTouchControlsStub.c`).
- Presenter ABI: `present(ctx, const HPPresentInfo*)`. The info struct only grows
  by appending fields. Also `HP_SetEyeCount`, `HP_SetScreenGeometry` (values are
  stored only for now). For WP3: one output texture per eye (`out[2]`), not a
  shared fb0, and the host must not assume exactly one present per frame.
- `GfxWindowBackendHost::IsFrameReady` (not `HandleEvents`) parks the game thread
  on the condvar while inactive (up to 100 ms per call), because SoH's loop polls
  `WindowIsFrameReady` before running a frame.
- SDL2 is built with `SDL_HIDAPI=OFF` too (SDL 2.32 omits `hidapi/ios/hid.m` for
  visionOS; it only added BLE Steam Controllers). Gamepads go through MFi.

SDL video calls that need guards: `SDL_GetDisplayUsableBounds` (`Gui.cpp:84`,
`OTRGlobals.cpp:140`). Calls that just fail harmlessly: `SDL_ShowSimpleMessageBox`,
`SDL_SetClipboardText`, `SDL_StartTextInput`.

## Risks

- metal-cpp, libzip, StormLib and the rest are untested for xros.
- Judder if the game runs at 60 fps on a 90 Hz compositor.
- ROM import from Files on visionOS.
- Every source change needs the fork → gitlink → `sources.lock.json` chain
  (`scripts/verify-sources.py`).
