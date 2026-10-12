import SwiftUI
import RealityKit
import GameController
import CoreGraphics
import os

/// Cinema screen geometry, in the immersive space's frame (origin on the floor
/// under the person, -Z ahead). 16:9, centre a little below a seated/standing
/// eye height so the eyes rest slightly down. Override the height with the
/// `CinemaHeight` default (meters) if it sits wrong.
private enum Screen {
    static let width: Float = 4.5
    static let distance: Float = 5.0
    static var height: Float {
        let h = UserDefaults.standard.float(forKey: "CinemaHeight")
        return h > 0 ? h : 1.35
    }
    static var center: SIMD3<Float> { [0, height, -distance] }
}

/// "Cine": the game on a large world-anchored stereo screen in a dark, fully
/// immersive room. Same pipeline as the 3D window (StereoGamePresenter: ring ->
/// LowLevelTextures -> StereoMaterial); the window is closed meanwhile, so only
/// this presenter is attached. Nothing overlaps the screen: the FPS meter sits
/// above its top edge and the exit/FPS panel low and near, below the line of
/// sight to the screen's bottom edge. Exit: the panel's button, holding L3+R3
/// (both stick clicks) for 1 s, or the Digital Crown.
struct CinemaView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @State private var model = AppModel.shared
    @State private var presenter = StereoGamePresenter()
    @State private var ghosts = SenseGhosts()
    @State private var exitCombo = ExitCombo()
    @State private var frameUpdates: EventSubscription?
    @State private var leaving = false
    private let log = Logger(subsystem: "com.nscabezon.sohvision", category: "Cinema")

    var body: some View {
        RealityView { content, attachments in
            content.add(await Self.makeRoom())
            do {
                let plane = try await presenter.makePlane()
                plane.scale = SIMD3(repeating: Screen.width)
                plane.position = Screen.center
                content.add(plane)
            } catch {
                log.error("cinema screen failed: \(String(describing: error), privacy: .public)")
            }
            content.add(ghosts.root)
            if let meter = attachments.entity(for: "fps") {
                // In the screen's plane, just above its top edge; scaled up to read at 5 m.
                meter.position = Screen.center + [0, Screen.width * 9 / 32 + 0.25, 0.01]
                meter.scale = SIMD3(repeating: 3)
                content.add(meter)
            }
            if let panel = attachments.entity(for: "panel") {
                // Low and near, like a remote on a table. The sight line from a seated
                // (1.2 m) or standing (1.7 m) eye to the screen's bottom edge passes
                // 0.85-1.2 m high here, so the panel (top ~0.8 m) never covers the screen.
                panel.position = [0, 0.72, -1.4]
                panel.orientation = simd_quatf(angle: -0.45, axis: [1, 0, 0])
                content.add(panel)
            }
            frameUpdates = content.subscribe(to: SceneEvents.Update.self) { event in
                MainActor.assumeIsolated {
                    let dt = Float(event.deltaTime)
                    ghosts.update(dt: dt)
                    if exitCombo.update(dt: dt) { exitCinema() }
                }
            }
        } attachments: {
            Attachment(id: "fps") {
                if model.showFPS {
                    FPSBadge(monitor: PerfMonitor.shared)
                }
            }
            Attachment(id: "panel") {
                CinemaPanel(model: model, exit: exitCinema)
            }
        }
        // The window that claimed the gamepad is closed: claim it here, or
        // visionOS turns the controller into a system pointer.
        .handlesGameControllerEvents(matching: .gamepad)
        .onAppear {
            model.cinema = .open
            _ = HPVisionHost.startEngine() // no-op once started (the window starts it)
            presenter.layout(widthPoints: 1920, widthMeters: Screen.width, displayScale: 1,
                             distanceMeters: Screen.distance)
            presenter.activate()
            updateActive()
            PerfMonitor.shared.setMode("Cine")
            log.notice("cinema open: screen \(Screen.width) m wide at \(Screen.distance) m, centre \(Screen.height) m high")
            Task { await ghosts.start() }
        }
        .onDisappear {
            frameUpdates?.cancel()
            frameUpdates = nil
            ghosts.stop()
            presenter.deactivate()
            model.cinema = .closed
            // Also when the system closed the space (Digital Crown): bring the game back.
            if !model.windowOpen { openWindow(id: AppModel.windowID) }
            log.notice("cinema closed")
        }
        .onChange(of: scenePhase) { updateActive() }
    }

    private func updateActive() {
        HP_SetActive(scenePhase == .active ? 1 : 0)
        HP_SetEyeCount(2)
    }

    private func exitCinema() {
        guard !leaving else { return }
        leaving = true
        if !model.windowOpen { openWindow(id: AppModel.windowID) }
        Task { await dismissImmersiveSpace() }
    }

    /// Dark room: a near-black sky sphere and a floor with a faint glow under
    /// the screen. Unlit, no assets.
    private static func makeRoom() async -> Entity {
        let room = Entity()
        room.name = "CinemaRoom"
        let sky = ModelEntity(mesh: .generateSphere(radius: 40),
                              materials: [UnlitMaterial(color: UIColor(red: 0.012, green: 0.012, blue: 0.02, alpha: 1))])
        sky.scale = [-1, 1, 1] // inside out: faces point inward
        room.addChild(sky)

        var floorMaterial = UnlitMaterial(color: UIColor(red: 0.012, green: 0.012, blue: 0.02, alpha: 1))
        if let glow = floorGlow(), let tex = try? await TextureResource(image: glow, options: .init(semantic: .color)) {
            floorMaterial.color = .init(tint: .white, texture: .init(tex))
        }
        let floor = ModelEntity(mesh: .generatePlane(width: 30, depth: 30), materials: [floorMaterial])
        floor.position = [0, 0, -Screen.distance]
        room.addChild(floor)

        // A thin black bezel just behind the screen.
        let bezel = ModelEntity(mesh: .generatePlane(width: Screen.width + 0.06, height: Screen.width * 9 / 16 + 0.06),
                                materials: [UnlitMaterial(color: .black)])
        bezel.position = Screen.center - [0, 0, 0.01]
        room.addChild(bezel)
        return room
    }

    /// Radial gradient for the floor: dim blue-grey at the centre (under the
    /// screen) fading into the sky colour.
    private static func floorGlow() -> CGImage? {
        let size = 512
        guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let gradient = CGGradient(
                colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                colors: [CGColor(srgbRed: 0.11, green: 0.11, blue: 0.15, alpha: 1),
                         CGColor(srgbRed: 0.012, green: 0.012, blue: 0.02, alpha: 1)] as CFArray,
                locations: [0, 1])
        else { return nil }
        ctx.setFillColor(CGColor(srgbRed: 0.012, green: 0.012, blue: 0.02, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        let c = CGPoint(x: size / 2, y: size / 2)
        ctx.drawRadialGradient(gradient, startCenter: c, startRadius: 0, endCenter: c,
                               endRadius: CGFloat(size) * 0.45, options: [])
        return ctx.makeImage()
    }
}

/// Exit button and FPS toggle, on the low panel near the person.
private struct CinemaPanel: View {
    @Bindable var model: AppModel
    let exit: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 16) {
                Button("Salir del cine", systemImage: "xmark", action: exit)
                Toggle("FPS", isOn: $model.showFPS)
                    .toggleStyle(.button)
            }
            .padding()
            .glassBackgroundEffect()
            Text("o mantén L3 + R3 1 s")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// Exit combo: both stick clicks held for 1 s. Unmapped in SoH's default
/// controls (and only ImGui's L3/R3 keys, unused by the menu), reachable on a
/// DualSense and on a Sense pair (each controller's stick click). Polled from
/// GameController, so it does not depend on the engine.
@MainActor
final class ExitCombo {
    private var held: Float = 0
    private var fired = false

    /// True once per hold, when it reaches 1 s.
    func update(dt: Float) -> Bool {
        guard Self.bothSticksPressed() else {
            held = 0
            fired = false
            return false
        }
        held += dt
        guard held >= 1, !fired else { return false }
        fired = true
        return true
    }

    private static func bothSticksPressed() -> Bool {
        var sense = [false, false]
        for c in GCController.controllers() {
            if c.productCategory == GCProductCategorySpatialController {
                if c.physicalInputProfile.buttons["Thumbstick Button"]?.isPressed == true {
                    sense[SenseGhosts.hand(of: c)] = true
                }
            } else if let g = c.extendedGamepad,
                      g.leftThumbstickButton?.isPressed == true, g.rightThumbstickButton?.isPressed == true {
                return true
            }
        }
        return sense[0] && sense[1]
    }
}
