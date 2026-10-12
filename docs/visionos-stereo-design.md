# Phase 3 — true per-eye stereo on Apple Vision Pro

Prefixes: `LUS=sources/Shipwright/libultraship`, `SOH=sources/Shipwright/soh`.
Companion to `visionos-design.md` (phase 1).

## Summary

Stereo goes into the Fast3D interpreter: the projection matrix is adjusted per
eye when it is loaded. The game only supplies per-view tags (`Mtx*`) for
convergence and mode. The two passes are kept apart with a per-eye framebuffer
alias table. Build presentation **A (RealityKit stereo window)** first, gated on a
device spike; **B-cinema (CompositorServices, Klepton-style)** second.

## 1. Where the eye cameras go

Today: the main view is applied in `func_800AAA9C` (`SOH/src/code/z_view.c:291`):
projection `G_MTX_LOAD|G_MTX_PROJECTION` (`:450-452`), then the viewing matrix is
**multiplied onto the projection stack** `G_MTX_MUL|G_MTX_PROJECTION` (`:476-477`).
In `Interpreter::GfxSpMatrix` (`LUS/src/fast/interpreter.cpp:1437`) `P = viewing·proj`
(row-vector convention). The modelview stack only holds model matrices.

Approach (interpreter + game hints):

- On LOAD of a **perspective** projection (`|m[3][3]|≈0`, `m[2][3]≠0`), store
  `P' = T(−h)·P·S(k)`: `h = σ·sep/2` (σ = −1 left, +1 right), `S` an off-axis clip
  shear `x += k·w`, `k = P00·h/D`, `D` = convergence distance. The later viewing MUL
  yields `viewing·T·P·S`, so the offset is in view space and correct for any camera
  orientation. Per vertex: `x_eye = x − h·P00 + k·w`; **y, z, w unchanged** (depth,
  fog and near clip untouched). Orthographic projections get a constant HUD offset.
- Game hints: `Stereo_TagProjection(Mtx*, class, D)`, keyed by `Mtx*` address like
  `mtx_replacements` (survives frame interpolation). Classes: world / HUD / off.
  World: `func_800AAA9C`, `func_800AB9EC` (`:642`, used by `z_play.c:1438`).
  HUD: `func_800AB560` (`:570`, interface perspective in `z_parameter.c:5223`),
  `func_800AB0A8` (`:485`), `func_800AB2C4` (`:520`). Untagged: perspective → world,
  ortho → HUD.
- Not (b) "change the view in the game": it needs duplicated display lists or new
  opcodes and breaks interpolated replay (`OTRGlobals.cpp:1870-1888`).

| Element | Problem | Fix |
|---|---|---|
| HUD rects (`GfxDrawRectangle` `:2768`) | sits at convergence plane | ±d px per eye when `!mFbActive` and width < 95% of screen; same for ImGui via `DrawData->DisplayPos.x` |
| Skybox (`z_vr_box_draw.c:16`, centred on mid-eye) | slightly less parallax than infinity | acceptable |
| Billboards | correct (parallel cameras share rotation) | reason toe-in is rejected |
| Prerendered backgrounds (`z_room.c:258` `Room_DrawBackground2D`) | flat 2D plate with 3D actors | room tag lowers `sep` (v1 mono); v2 shift plate to fixed depth |
| Framebuffer copies (`gfx_set_fb_handler_custom` `:4067`, `CopyFrameBuffer` `:5161`, `gfx_set_timg_fb_handler_custom` `:4172`, `mFbTextures` `:1219`) | second pass reusing ids clobbers eye 0 | **per-eye framebuffer alias table** incl. `mGameFb`, `mGameFbMsaaResolved` → pause background (`z_play.c:1616`) and VisMono (`z_vismono.c:156`) stay stereo |
| `gfx_read_fb_handler_custom` (`:4109`, camera photo) | CPU readback | eye 0 only |
| `GetPixelDepth` (`:5223`; lens flares `z_kankyo.c:235`, `z_lights.c:403`) | computed for mid-eye | read eye 0 `mGameFb`, correct x by disparity |
| Actor culling (central frustum) | pop-in at the edge | hidden by window frame |
| CPU face culling (`GfxSpTri1:1731`) | only matters single-pass | make conservative |

## 2. Separation and convergence

- World scale: adult Link 68 units (`Player_GetHeight`, `z_actor.c:1401`), child 44.
  ~1.7 m → 1 unit ≈ 2.5 cm; real IPD 63 mm ≈ 2.5 units.
- Off-axis, never toe-in (vertical parallax, keystone).
- User parameter `p` = parallax at infinity as a fraction of image width:
  `sep = 2·D·p / P00_eff` (`P00_eff` includes `AdjXForAspectRatio`).
  Divergence cap `p_max = IPD_real / screen_width_m` (≈4.5% for a 1.4 m screen), sent by the host.
  Example D = 250, fovy 60, 16:9, p = 3% → sep ≈ 15 units (6× real: miniature look, like the 3DS).
- Default D = `|view->eye − player focus|` clamped to [60, 800], smoothed ~0.3 s, snapping
  on `FrameInterpolation_DontInterpolateCamera` (`z_view.c:402`).
- Settings (`SohMenuSettings.cpp`): "3D depth" slider (0–100% of `p_max`), convergence bias, HUD depth.

## 3. Presentation

- **(A) RealityKit magic window**: `RealityView` plane, `ShaderGraphMaterial` with
  `CameraIndexSwitch` over two `LowLevelTexture`s. Maps directly onto the phase-1
  presenter (`present(info)` → `llt[eye].replace(using: cmdbuf)` + blit). Works in the
  Shared Space; system does head tracking and 90 Hz reprojection; most comfortable.
  Unverified: material + `replace` threading; the simulator does not show stereo;
  negative parallax fights the window edges.
- **(B) CompositorServices** following Klepton (`KleptonCompositor.swift:1925` `renderFrame`:
  `queryNextFrame → wait(optimalInputTime) → queryDrawable → startSubmission`; never
  `endSubmission` without presenting (`:1937`); render every drawable; `layered`,
  foveation, `bgra8Unorm_srgb`, `depth32Float`).
  - **B-cinema**: world-anchored quad sampling each eye's texture; the game runs async and
    the compositor recomposes at 90 Hz (`kl_reproject` pattern). Comfortable, big screen, own environment.
  - **B-VR**: game camera + head delta (metres → units) with `views[i].transform`.
    Motion-sickness risk (automatic third-person camera), FOV ~100° vs 60° culling, HUD placement. Experimental.
- Order: A (gated on spike S0) → B-cinema if A fails → B-VR last.

## 4. Performance

- Two full passes: interpreter CPU ×2 (`GfxSpVertex` with lighting dominates; second pass
  hits the texture cache). 90 fps = 180 `Run`/s. GPU ×2 but N64 polys are cheap; fill rate per eye dominates.
- Pacing: interpolation (`Graph_ProcessGfxCommands`) must use divisors of 90 (90/45/30), never 60.
- Single interpretation is possible (eyes differ by `x += c + k·w` per draw state) — phase 3b:
  `c`,`k` as per-draw uniforms with a flush on projection load, Metal vertex amplification ×2,
  2-layer framebuffers via `[[render_target_array_index]]`, culling/`clip_rej` as union of both eyes.
  CPU ×1 but invasive in `gfx_metal`; only if 3a measurements demand it.

## 5. Plan

| WP | Files | Done when |
|---|---|---|
| S0 device spike | `visionos/SoHVision/Stereo*` | different pattern per eye on device, updated from a background thread |
| S1 stereo core | `interpreter.cpp/.h`: `StereoParams`, `SetEye()`, fix in `GfxSpMatrix:1468-1474`, rect offsets, fb alias table, per-eye `hasCopied`, readback/`GetPixelDepth` eye 0 only | eyeCount=1 pixel-identical (regression); eyeCount=2 dump shows x-only disparity |
| S2 Metal | `gfx_metal.cpp`: split `StartFrame` (`:558`) into frame/eye level (don't reset offset at `:572`); vertex pool ×2 (`:86`) | Metal validation clean |
| S3 loop | `Fast3dWindow.cpp:210-233` eye loop; `Fast3dGui.cpp:362` composite per eye (render `ImDrawData` twice swapping the game `TextureId`) | two presents per frame |
| S4 SoH | tags in `z_view.c`, `z_room.c`, settings, CVars | HUD floats in front; prerendered rooms fine |
| S5 host | presenter → `LowLevelTexture`, `HP_SetScreenGeometry` | stable 3D at 90/45 Hz |
| S6/S7/S8 | B-cinema / 3b single pass / B-VR | — |

Order: S0, S1, S2 in parallel (disjoint files) → S3 → S4, S5.

### What phase 1 must anticipate (applied to `gfx_host.h`)

1. Presenter takes a struct: `present(ctx, const HPPresentInfo*)` with
   `{texture, commandBuffer, eye, eyeCount, frameIndex, width, height}` (ABI can grow).
2. One output texture per eye (`out[2]`), not one shared fb0 — both eyes are encoded in the same command buffer.
3. Game + ImGui composition in a function that takes the game texture and can run N times.
4. The host must not assume one present per frame.
5. API reserves `HP_SetEyeCount` and `HP_SetScreenGeometry(widthM, distM)`.
6. Metal `StartFrame`/`EndFrame` ready to split; configurable vertex pool size.

## 6. Risks

1. CPU cost of two passes at 90 Hz on M2 unmeasured — measure early in S1.
2. `CameraIndexSwitch` + `LowLevelTexture` in a window unverified; `replace` may need the
   MainActor (solve with `MTLSharedEvent`). Needs the device (S0).
3. Side effects of running `Run` twice: `copyOnce`, readbacks, `mFbTextures`, sun flare.
4. Vertex pool has no fence (3 buffers, no semaphore); doubled load raises overflow risk.
5. Comfort: vergence jumps on camera cuts; divergence if screen width unknown.
6. Every LUS/SoH change goes through the fork → gitlink → `sources.lock.json` chain.
