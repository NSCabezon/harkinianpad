# Running SoHVision (visionOS)

## Build

```sh
scripts/build-visionos.sh              # engine for the simulator -> build-visionos-sim/
scripts/build-visionos.sh --device     # engine for Apple Vision Pro -> build-visionos/
open visionos/SoHVision.xcodeproj      # then Run (scheme SoHVision) on a simulator or the device
```

The Xcode project links `libSoHEngine.a` from the build directory that matches
the SDK and copies `soh.o2r`, `gamecontrollerdb.txt` and `assets/` into the app.
Rebuild the engine after changing anything under `sources/`.

## First run

1. Put a supported ROM (e.g. `roms/oot-pal-gc.z64`) in the app's **Documents**
   folder: Files app on the headset, or from the Mac:
   ```sh
   xcrun devicectl device copy to --device <UDID> --domain-type appDataContainer \
     --domain-identifier com.nscabezon.sohvision --source roms/oot-pal-gc.z64 \
     --destination Documents/oot-pal-gc.z64
   ```
   Simulator: `xcrun simctl get_app_container <udid> com.nscabezon.sohvision data`.
2. Launch. With no `oot.o2r` the engine scans Documents and extracts the ROM
   without prompts (~1 min), then boots to the title screen.

## HD textures

Copy `mods-local/OoT_Reloaded_v11.0.0_HD.o2r` to `Documents/mods/` and enable it
in the SoH menu (Mod Menu), or set `gSettings.Mods.EnabledPaths` to
`["OoT_Reloaded_v11.0.0_HD.o2r"]` in `Documents/shipofharkinian.json`.

## Controls

DualSense (any extended gamepad). **Create/Share** opens the SoH menu; navigate
with the D-pad/stick, Cross to accept, Circle to go back. The PS button belongs to
the system on visionOS.

## Stereo spike

The **Stereo test** ornament under the window (or launching with
`-StereoSpike YES`) shows the S0 per-eye test: on the headset the left eye should
see red with one dot and the right eye blue with two dots, with the white bar
floating in front of the window.

## Cinema ("Cine")

**Cine** in the bottom ornament (or launching with `-StartCinema YES`) opens a fully
immersive space (`ImmersiveSpace` `cinema`, style `.full`) and closes the window: the
game plays on a world-anchored stereo screen 4.5 m wide (16:9), 5 m ahead, centre
1.35 m above the floor (`-CinemaHeight <m>` overrides), in a dark room. Same pipeline
as 3D (`StereoGamePresenter`), render 1920×1080 per eye, `HP_SetScreenGeometry(4.5, 5)`.

- Exit: hold **L3 + R3** (click both sticks; on a Sense pair, one stick each) for 1 s,
  or **Salir del cine** in the panel under the screen. Unmapped in SoH's default
  controls. Closing the space any other way (Digital Crown) reopens the window too.
- The panel also toggles the FPS meter (shown above it, mode `Cine`).
- Ghost controllers: resting PS VR2 Sense controllers show as translucent stand-ins
  at their grip pose (ARKit accessory + hand tracking, asked on first open; not in the
  simulator). Hidden while held: platform `heldChirality`, input in the last 2 s, or
  moving with a palm near / no hands tracked; shown after 1 s still with the hand away
  (2.5 s otherwise). Logs: category `Ghost`.

## Performance reports

**FPS** in the bottom ornament (or launching with `-ShowFPS YES`) shows a small
meter above the window, refreshed once per second:

| Line | Meaning |
|---|---|
| `3D · 2 eyes · 1920×1080` | view mode, eyes the engine rendered, engine render size per eye (px) |
| `game N fps` | frames the engine ran per second (OoT logic runs at 20) |
| `present N/s` (2D) | drawables presented to the window layer per second (on the display tick) |
| `replace N/s · drop N` (3D) | LowLevelTexture replaces per second; `drop` (both modes, in the log/CSV) = frames dropped (ring full) or superseded before the main thread took them |
| `cpu avg / max ms` | CPU time in `Interpreter::Run` per frame, all eyes (`HP_GetStats`) |
| `audio q N · underruns N` | audio frames queued in the SDL device (32 kHz; SoH targets 4096) and times the queue ran dry in the last second |

Every 5 s the app logs (subsystem `com.nscabezon.sohvision`, category `Perf`)

```
[Perf] mode=3D eyes=2 res=1920x1080 gameFps=45.0 presentFps=45.0 dropped=0 cpuMs avg/max=2.60/8.24 footprintMB=244 audioUnderruns=0 audioQueued=2032
```

and appends the same as a row to `Documents/perf.csv` (header written once when the
file is new; one write per row, nothing buffered):

`time,event,mode,eyes,width,height,gameFps,presentFps,dropped,cpuAvgMs,cpuMaxMs,footprintMB,audioUnderruns,audioQueued`

- `time` UTC ISO 8601; `event` = `report` (5 s window) or `mode` (2D/3D switch: the
  window so far is reported under the old mode first, then a `mode` row with the new
  mode, other columns 0 except the footprint; the log says `[Perf] mode change 2D -> 3D`).
- `dropped` counts frames in the window; `cpuMaxMs` is the worst single frame in it
  (scene loads show as spikes of hundreds of ms).
- `footprintMB` = `phys_footprint` (`task_info TASK_VM_INFO`), what jetsam counts.
- `audioUnderruns` = times new audio reached an empty SDL queue in the window;
  `audioQueued` = frames queued at report time. Columns are only appended; delete an
  old file to get the current header.

Pull the reports:

```sh
xcrun devicectl device copy from --device <UDID> --domain-type appDataContainer \
  --domain-identifier com.nscabezon.sohvision --source Documents/perf.csv --destination perf.csv
```

The log lines are in Console.app (select the headset, filter `category:Perf`) or the
Xcode console.

Simulator: `$(xcrun simctl get_app_container <udid> com.nscabezon.sohvision data)/Documents/perf.csv`.
Delete the file to start a fresh one. `SOH_PERF_LOG=1` additionally logs the engine's
300-frame `Interpreter::Run` average and every shader compiled at runtime (`[Perf] shader
… compiled in N ms`, a source of hitches) to `Documents/logs/Ship of Harkinian.log`.

### Shader cache (first-use hitches)

Fast3D shaders are generated as MSL source and compiled at runtime; a cold compile costs
~150–170 ms (≈95% the MSL→library front end, pipelines ~3 ms each), which was the main
first-use hitch. Now:

- Every shader + msaa variant built is appended to `Documents/shader-cache.txt`
  (`id0 id1 flags msaa`, flags: 1 = three-point filter, 2 = sRGB). Delete it to start over.
- On launch two background threads compile the listed shaders (first-use order) and the game
  thread takes them when asked; it only compiles itself if one was never seen (or not reached
  yet — it then waits for an in-flight one rather than compiling twice). Pipelines are created
  only for the msaa level in use (was every supported level).
- First launch: the app bundles `assets/shader-cache-seed.txt` (title screen, attract demo and
  Kokiri Forest). Regenerate it after playing in the simulator with
  `scripts/generate-shader-seed.sh <UDID>`; it lives in `assets/visionos/` and
  `build-visionos.sh` copies it into `<build>/soh/assets/`, which the Copy Engine Resources
  phase already bundles.
- `SOH_SHADER_PRECOMPILE=0` disables the background compile (A/B tests). With `SOH_PERF_LOG`
  the log says, per shader, `compiled on the game thread in N ms (library …, pipeline …)` or
  `ready from precompile`, plus `[ShaderCache]` totals, and texture imports/resource loads
  that take ≥ 2 ms.
- `MTLBinaryArchive` is not used: it only caches the pipeline back end, a few ms of the cost.

### Frame pacing

- One clock: a `CADisplayLink` in the host (`HPVisionHost`) calls `HP_DisplayTick` on
  every display refresh; the engine starts each frame on a tick (2 ticks per frame at
  45 fps on the 90 Hz panel) and only falls back to its own timer without ticks.
- The game thread never waits for a drawable: in 2D it draws into a one-eye ring
  (`HPStereoSink`) and the main thread presents the newest frame on the next tick; in
  3D the ring feeds the LowLevelTextures as before.
- visionOS defaults to 45 fps (`SOH_DEFAULT_INTERPOLATION_FPS`, only when the user never
  set *Current FPS*); any value above 20 is snapped to 90/45/30 (never 60). *Match
  Refresh Rate* gives 90.
- The 3D view renders at most 1920×1080 per eye (the 2D view uses the full drawable).
- The simulator's display link fires at ~60 Hz while reporting 90, so 45 fps alternates
  1 and 2 ticks there (a few `dropped` per window); on device it is a steady 2.
