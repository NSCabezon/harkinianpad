import SwiftUI
import UIKit
import Metal
import RealityKit
import os

// S5 — host stereo presentation, option A ("magic window").
//
//   game thread (HPPresent, engine cmdbuf)          main actor (this file)
//   ──────────────────────────────────────          ──────────────────────
//   eye 0: acquire free ring slot (else drop)
//   eye e: draw info->texture -> ring[slot][e]
//   last eye: encodeSignalEvent(event, v);
//             publish {v, slot, mono}  ──hop──▶     takeLatestFrame
//   (engine commits)                                cmd.encodeWaitForEvent(event, v)
//                                                   llt[L/R].replace(using: cmd) + blit
//                                                   completion -> releaseSlot
//
// Mono (engine sends eye 0 only): ring[slot][0] is blitted to both eyes.
// The ShaderGraph material (StereoMaterial.usda, CameraIndexSwitch) shows the
// left texture to camera 0 and in mono views (simulator), the right to camera 1.

/// Engine render sizes for the stereo view (16:9). The ring and the LowLevelTextures
/// follow the tier, so resizing the window only reallocates on a tier change.
/// Capped at 1920x1080 per eye: the default 1280 pt window would otherwise pick
/// 2560x1440, and stereo renders and copies every pixel twice (per eye: engine ->
/// ring -> LowLevelTexture). The 2D path keeps the full drawable size.
private let stereoTiers: [(Int, Int)] = [(1280, 720), (1920, 1080)]

/// Window distance is not observable in the Shared Space; visionOS opens windows
/// roughly at arm's length+. Verify on device (drives the divergence cap).
let assumedViewingDistanceM: Float = 1.2

@MainActor
final class StereoGamePresenter {
    private let device: MTLDevice?
    private let queue: MTLCommandQueue?
    private var sink: HPStereoSink?
    private var left: LowLevelTexture?
    private var right: LowLevelTexture?
    private var material: ShaderGraphMaterial?
    private weak var plane: ModelEntity?
    private var active = false
    private(set) var tier: (Int, Int) = (0, 0)
    private(set) var replacedFrames = 0
    private var lastGeometry: (Float, Float) = (0, 0)
    private let log = Logger(subsystem: "com.nscabezon.sohvision", category: "Stereo")

    init() {
        device = MTLCreateSystemDefaultDevice()
        queue = device?.makeCommandQueue()
        queue?.label = "soh.stereo.present"
    }

    var stats: (published: UInt64, dropped: UInt64, superseded: UInt64, taken: UInt64)? {
        guard let sink else { return nil }
        return (sink.publishedFrames, sink.droppedFrames, sink.supersededFrames, sink.takenFrames)
    }

    /// Builds the plane with the stereo material. Called once from RealityView make.
    func makePlane() async throws -> ModelEntity {
        let material = try await ShaderGraphMaterial(
            named: "/Root/StereoMaterial", from: "StereoMaterial.usda", in: Bundle.main)
        self.material = material
        let plane = ModelEntity(mesh: .generatePlane(width: 1, height: 9.0 / 16.0), materials: [material])
        plane.name = "StereoGamePlane"
        self.plane = plane
        if tier.0 > 0 {
            try rebuild(width: tier.0, height: tier.1)
        }
        return plane
    }

    func activate() {
        active = true
        if let sink { HPVisionHost.attachStereo(sink) }
    }

    func deactivate() {
        active = false
        if let sink { HPVisionHost.detachStereo(sink) }
    }

    /// The plane's on-screen size changed: pick the render tier, tell the engine
    /// its render size and the physical screen geometry. One presenter per view
    /// (window plane or cinema screen); the last one activated gets the frames.
    func layout(widthPoints: CGFloat, widthMeters: Float, displayScale: CGFloat,
                distanceMeters: Float = assumedViewingDistanceM) {
        guard widthPoints > 1, widthMeters > 0 else { return }
        let px = Int((widthPoints * max(displayScale, 1)).rounded())
        let chosen = stereoTiers.first(where: { $0.0 >= px }) ?? stereoTiers[stereoTiers.count - 1]
        if chosen != tier {
            tier = chosen
            log.info("stereo tier \(chosen.0)x\(chosen.1) (plane \(Int(widthPoints)) pt, \(widthMeters) m)")
            if material != nil {
                do { try rebuild(width: chosen.0, height: chosen.1) } catch {
                    log.error("stereo rebuild failed: \(String(describing: error))")
                }
            }
        }
        HP_SetViewSize(Int32(tier.0), Int32(tier.1))
        if abs(lastGeometry.0 - widthMeters) > 0.005 || lastGeometry.1 != distanceMeters {
            lastGeometry = (widthMeters, distanceMeters)
            HP_SetScreenGeometry(widthMeters, distanceMeters)
        }
    }

    /// New ring + LowLevelTextures at the tier size, bound to the material.
    private func rebuild(width: Int, height: Int) throws {
        guard let device, let queue, var material,
              let sink = HPStereoSink(device: device, width: width, height: height)
        else { throw StereoError.metalSetup }
        let desc = LowLevelTexture.Descriptor(
            textureType: .type2D, pixelFormat: .bgra8Unorm_srgb,
            width: width, height: height, depth: 1, mipmapLevelCount: 1,
            textureUsage: [.shaderRead, .shaderWrite, .renderTarget])
        let left = try LowLevelTexture(descriptor: desc)
        let right = try LowLevelTexture(descriptor: desc)
        try material.setParameter(name: "LeftTexture", value: .textureResource(try TextureResource(from: left)))
        try material.setParameter(name: "RightTexture", value: .textureResource(try TextureResource(from: right)))
        self.material = material
        plane?.model?.materials = [material]

        // Start black instead of uninitialised memory.
        if let cmd = queue.makeCommandBuffer() {
            for t in [left.replace(using: cmd), right.replace(using: cmd)] {
                let pass = MTLRenderPassDescriptor()
                pass.colorAttachments[0].texture = t
                pass.colorAttachments[0].loadAction = .clear
                pass.colorAttachments[0].storeAction = .store
                pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
                cmd.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
            }
            cmd.commit()
        }

        sink.frameReadyHandler = { [weak self] in
            MainActor.assumeIsolated { self?.presentLatest() }
        }
        self.left = left
        self.right = right
        if let old = self.sink { HPVisionHost.detachStereo(old) }
        self.sink = sink
        if active { HPVisionHost.attachStereo(sink) }
    }

    /// Main actor, once per published frame (coalesced hop from the game thread).
    private func presentLatest() {
        guard let sink, let left, let right, let queue else { return }
        var value: UInt64 = 0
        var slot = 0
        var mono: ObjCBool = false
        guard sink.takeLatestFrame(value: &value, slot: &slot, mono: &mono) else { return }
        guard let cmd = queue.makeCommandBuffer() else {
            sink.releaseSlot(slot)
            return
        }
        cmd.label = "stereo.replace.\(value)"
        cmd.encodeWaitForEvent(sink.event, value: value)
        guard let blit = cmd.makeBlitCommandEncoder() else {
            sink.releaseSlot(slot)
            return
        }
        let l = left.replace(using: cmd)
        let r = right.replace(using: cmd)
        blit.copy(from: sink.texture(slot: slot, eye: 0), to: l)
        blit.copy(from: sink.texture(slot: slot, eye: mono.boolValue ? 0 : 1), to: r)
        blit.endEncoding()
        let taken = slot
        cmd.addCompletedHandler { _ in sink.releaseSlot(taken) }
        cmd.commit()
        replacedFrames += 1
    }
}

/// The game as a RealityKit plane showing a different image to each eye.
struct StereoGameView: View {
    @Environment(\.displayScale) private var displayScale
    @State private var presenter = StereoGamePresenter()
    @State private var status = ""

    var body: some View {
        GeometryReader3D { proxy in
            RealityView { content in
                do {
                    content.add(try await presenter.makePlane())
                } catch {
                    status = "Error: \(error)"
                }
            } update: { content in
                // Fit the 1 m-wide plane to the view's frame in scene meters.
                let frame = proxy.frame(in: .local)
                let box = content.convert(frame, from: .local, to: .scene)
                let fitW = min(box.extents.x, box.extents.y * 16.0 / 9.0)
                guard fitW > 0.001 else { return }
                if let plane = content.entities.first(where: { $0.name == "StereoGamePlane" }) {
                    plane.scale = SIMD3(repeating: fitW)
                    // The window surface sits half the view's depth behind the box
                    // `convert` reports (measured in the simulator: at box.min.z the
                    // plane floats in front, 1.35x too big, and hides the ornament;
                    // at -depth it is hidden behind the window). 2 mm in front of it.
                    plane.position = SIMD3(box.center.x, box.center.y, box.min.z - box.extents.z * 0.5 + 0.002)
                }
                let widthPts = min(frame.size.width, frame.size.height * 16.0 / 9.0)
                presenter.layout(widthPoints: widthPts, widthMeters: fitW, displayScale: displayScale)
            }
        }
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .background(WindowAspectLock())
        .overlay(alignment: .center) {
            if !status.isEmpty {
                Text(status).padding().glassBackgroundEffect()
            }
        }
        .onAppear { presenter.activate() }
        .onDisappear { presenter.deactivate() }
    }
}

/// Keeps the window at a uniform (16:9) aspect while the person resizes it,
/// as GameSurfaceUIView does for the flat path.
private struct WindowAspectLock: UIViewRepresentable {
    final class LockView: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            window?.windowScene?.requestGeometryUpdate(.Vision(resizingRestrictions: .uniform))
        }
    }

    func makeUIView(context: Context) -> LockView {
        let v = LockView()
        v.isUserInteractionEnabled = false
        return v
    }

    func updateUIView(_ uiView: LockView, context: Context) {}
}
