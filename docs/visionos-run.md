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
