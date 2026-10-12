import ARKit
import RealityKit
import GameController
import QuartzCore
import os

/// "Ghost" PS VR2 Sense controllers for the cinema space (ported and simplified
/// from AlyxAVP: KleptonControllers.ghostSample, KleptonHUD KLGhostHand).
///
/// In full immersion the real controllers are invisible; a translucent stand-in
/// at each controller's `.grip` pose shows where a RESTING controller lies so it
/// can be picked up. It hides while the controller is in a hand. ARKit
/// (AccessoryTrackingProvider + HandTrackingProvider) only runs inside an open
/// immersive space and not in the simulator: there the ghosts are simply off.
/// The DualSense is not trackable and never gets one.
@MainActor
final class SenseGhosts {
    let root = Entity()

    private let session = ARKitSession()
    private let hands = HandTrackingProvider()
    private var accessoryAnchors: [AccessoryAnchor?] = [nil, nil]
    private var states = [GhostState(), GhostState()]
    private var models: [Entity] = []
    private var lastInput: [TimeInterval] = [-100, -100]
    private var trackedControllers: [GCController] = []
    private var anchorTask: Task<Void, Never>?
    private var running = false
    private let log = Logger(subsystem: "com.nscabezon.sohvision", category: "Ghost")

    init() {
        root.name = "SenseGhosts"
        for hand in 0...1 {
            let model = Self.makeModel()
            model.name = hand == 0 ? "GhostLeft" : "GhostRight"
            model.isEnabled = false
            root.addChild(model)
            models.append(model)
        }
    }

    /// Starts tracking (the cinema space just opened).
    func start() async {
        guard AccessoryTrackingProvider.isSupported else {
            log.notice("[ghost] accessory tracking not supported here (simulator?): ghost controllers off")
            return
        }
        running = true
        await runSession()
    }

    func stop() {
        running = false
        anchorTask?.cancel()
        anchorTask = nil
        session.stop()
        accessoryAnchors = [nil, nil]
    }

    /// The provider's accessory list is fixed when the session runs, so a new
    /// pairing (or a controller waking up) re-runs it with a rebuilt list,
    /// without stopping it first (as AlyxAVP does).
    private func runSession() async {
        trackedControllers = Self.senseControllers()
        let accessories = await Self.makeAccessories()
        guard running else { return }
        let provider = AccessoryTrackingProvider(accessories: accessories)
        var providers: [any DataProvider] = [provider]
        if HandTrackingProvider.isSupported { providers.append(hands) }
        do {
            try await session.run(providers)
        } catch {
            log.error("[ghost] ARKit session failed: \(String(describing: error), privacy: .public)")
            return
        }
        log.notice("[ghost] tracking \(accessories.map(\.name), privacy: .public), hands \(HandTrackingProvider.isSupported)")
        accessoryAnchors = [nil, nil]
        anchorTask?.cancel()
        anchorTask = Task { [weak self] in
            for await update in provider.anchorUpdates {
                guard let self, !Task.isCancelled else { return }
                let anchor = update.anchor
                // A controller that has not said which hand it is: right (one-handed play).
                let hand = anchor.accessory.inherentChirality == .left ? 0 : 1
                self.accessoryAnchors[hand] = update.event == .removed ? nil : anchor
            }
        }
    }

    /// Once per rendered frame (SceneEvents.Update).
    func update(dt: Float) {
        guard running else { return }
        let controllers = Self.senseControllers()
        if controllers != trackedControllers {
            trackedControllers = controllers
            Task { await runSession() }
        }
        let now = CACurrentMediaTime()
        for c in controllers where Self.hasInput(c) {
            lastInput[Self.hand(of: c)] = now
        }
        var palms: [SIMD3<Float>] = []
        if hands.state == .running {
            for a in [hands.latestAnchors.leftHand, hands.latestAnchors.rightHand] {
                if let a, a.isTracked { palms.append(Self.palm(a)) }
            }
        }
        for h in 0...1 {
            states[h].update(hand: h, sample: sample(h), palms: palms,
                             handsSeen: !palms.isEmpty, lastInput: lastInput[h],
                             now: now, dt: dt, log: log)
            let model = models[h]
            model.isEnabled = states[h].alpha > 0
            if model.isEnabled {
                model.transform = Transform(matrix: states[h].pose)
                model.components.set(OpacityComponent(opacity: states[h].alpha))
            }
        }
    }

    private func sample(_ hand: Int) -> GhostSample? {
        guard let a = accessoryAnchors[hand] else { return nil }
        let m = a.accessory.locations.contains(.grip)
            ? a.coordinateSpace(for: .grip, correction: .rendered).ancestorFromSpaceTransformFloat().matrix
            : a.originFromAnchorTransform
        let positioned: Bool
        switch a.trackingState {
        case .positionOrientationTracked, .positionOrientationTrackedLowAccuracy: positioned = true
        case .untracked, .orientationTracked: positioned = false
        @unknown default: positioned = a.isTracked
        }
        return GhostSample(originFromGrip: m, positionTracked: positioned && a.isTracked,
                           heldByPlatform: a.heldChirality != nil,
                           speed: simd_length(a.velocity), angularSpeed: simd_length(a.angularVelocity))
    }

    // MARK: - Controllers

    /// Off the main actor: `Accessory(device:)` takes the GCController across.
    /// One failure must not take the other controller with it.
    nonisolated private static func makeAccessories() async -> [Accessory] {
        var accessories: [Accessory] = []
        for c in GCController.controllers() where c.productCategory == GCProductCategorySpatialController {
            do { accessories.append(try await Accessory(device: c)) } catch {
                Logger(subsystem: "com.nscabezon.sohvision", category: "Ghost")
                    .error("[ghost] Accessory init failed for \(c.vendorName ?? "?", privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
        return accessories
    }

    static func senseControllers() -> [GCController] {
        GCController.controllers().filter { $0.productCategory == GCProductCategorySpatialController }
    }

    /// 0 = left, 1 = right ("PlayStation VR2 Sense Controller (L)").
    static func hand(of c: GCController) -> Int {
        (c.vendorName ?? "").hasSuffix("(L)") ? 0 : 1
    }

    /// Any sign of a hand on the controller: a button or trigger (pressed or
    /// capacitive touch) or the stick off-centre.
    private static func hasInput(_ c: GCController) -> Bool {
        let p = c.physicalInputProfile
        for b in p.buttons.values where b.value > 0.05 || b.isTouched { return true }
        for d in p.dpads.values where abs(d.xAxis.value) > 0.2 || abs(d.yAxis.value) > 0.2 { return true }
        return false
    }

    /// Palm centre: between the middle finger's metacarpal and knuckle.
    private static func palm(_ a: HandAnchor) -> SIMD3<Float> {
        let o = a.originFromAnchorTransform
        guard let sk = a.handSkeleton else { return SIMD3(o.columns.3.x, o.columns.3.y, o.columns.3.z) }
        let b = (o * sk.joint(.middleFingerMetacarpal).anchorFromJointTransform).columns.3
        let k = (o * sk.joint(.middleFingerKnuckle).anchorFromJointTransform).columns.3
        return SIMD3((b.x + k.x) / 2, (b.y + k.y) / 2, (b.z + k.z) / 2)
    }

    // MARK: - Model

    /// Translucent stand-in in the grip frame: a handle along Z through the grip
    /// and the tracking ring around its front (-Z) end. Approximate fit.
    private static func makeModel() -> Entity {
        var material = UnlitMaterial(color: UIColor(white: 0.85, alpha: 1))
        material.blending = .transparent(opacity: 0.45)
        let model = Entity()
        let handle = ModelEntity(mesh: .generateCylinder(height: 0.10, radius: 0.019), materials: [material])
        handle.orientation = simd_quatf(angle: .pi / 2, axis: [1, 0, 0]) // cylinder Y -> Z
        model.addChild(handle)
        for z: Float in [-0.05, 0.05] {
            let cap = ModelEntity(mesh: .generateSphere(radius: 0.019), materials: [material])
            cap.position = [0, 0, z]
            model.addChild(cap)
        }
        if let ring = try? MeshResource.generate(from: [torus(major: 0.05, minor: 0.007)]) {
            let e = ModelEntity(mesh: ring, materials: [material])
            e.position = [0, 0.01, -0.07]
            model.addChild(e)
        }
        return model
    }

    /// Torus in the XY plane (axis Z).
    private static func torus(major: Float, minor: Float, segments: Int = 32, sides: Int = 8) -> MeshDescriptor {
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        for i in 0..<segments {
            let u = Float(i) / Float(segments) * 2 * .pi
            let dir = SIMD3<Float>(cos(u), sin(u), 0)
            for j in 0..<sides {
                let v = Float(j) / Float(sides) * 2 * .pi
                let n = dir * cos(v) + SIMD3<Float>(0, 0, 1) * sin(v)
                positions.append(dir * major + n * minor)
                normals.append(n)
            }
        }
        var indices: [UInt32] = []
        for i in 0..<segments {
            for j in 0..<sides {
                let a = UInt32(i * sides + j)
                let b = UInt32(((i + 1) % segments) * sides + j)
                let c = UInt32(((i + 1) % segments) * sides + (j + 1) % sides)
                let d = UInt32(i * sides + (j + 1) % sides)
                indices += [a, b, c, a, c, d]
            }
        }
        var desc = MeshDescriptor(name: "ring")
        desc.positions = MeshBuffers.Positions(positions)
        desc.normals = MeshBuffers.Normals(normals)
        desc.primitives = .triangles(indices)
        return desc
    }
}

/// One Sense controller as the ghost logic sees it.
struct GhostSample {
    var originFromGrip: simd_float4x4 // ARKit origin (= immersive space), `.grip`, rendered correction
    var positionTracked: Bool         // false: untracked or orientation only
    var heldByPlatform: Bool          // AccessoryAnchor.heldChirality != nil
    var speed: Float                  // m/s
    var angularSpeed: Float           // rad/s
}

/// In-hand decision for one controller with hysteresis (KLGhostHand, simplified).
///
/// HELD (hidden) when any of: the platform says so (`heldChirality`); input on
/// that controller in the last 2 s; it moved in the last 0.6 s (> 8 cm/s,
/// > 0.9 rad/s or > 2.5 cm from its rest point) while a palm is within 9 cm
/// (12 cm to leave) or no hand is tracked (visionOS stops reporting hands that
/// hold controllers). A palm near a still controller does not hide it: that is
/// the hand reaching for it.
/// RESTING (shown) after 1 s without evidence when a tracked hand is away,
/// else after 2.5 s. Not position-tracked: hidden. 200 ms fades.
struct GhostState {
    private(set) var alpha: Float = 0
    private(set) var pose = matrix_identity_float4x4
    private var visible = false
    private var lastHeldEvidence: TimeInterval = -100
    private var lastMotion: TimeInterval = -100
    private var restPos: SIMD3<Float>?
    private var palmNear = false

    static let inputWindow: TimeInterval = 2.0
    static let showAfter: TimeInterval = 2.5
    static let nearIn: Float = 0.09, nearOut: Float = 0.12

    mutating func update(hand: Int, sample: GhostSample?, palms: [SIMD3<Float>], handsSeen: Bool,
                         lastInput: TimeInterval, now: TimeInterval, dt: Float, log: Logger) {
        var show = false
        let reason: String
        if let s = sample, s.positionTracked {
            pose = s.originFromGrip
            let p = SIMD3<Float>(pose.columns.3.x, pose.columns.3.y, pose.columns.3.z)
            if s.speed > 0.08 || s.angularSpeed > 0.9 { lastMotion = now }
            if let r = restPos, simd_distance(p, r) <= 0.025 {} else {
                if restPos != nil { lastMotion = now }
                restPos = p
            }
            let d = palms.map { simd_distance($0, p) }.min() ?? .infinity
            palmNear = d < (palmNear ? Self.nearOut : Self.nearIn)
            let moved = now - lastMotion < 0.6
            let input = now - lastInput < Self.inputWindow
            if s.heldByPlatform || input || (moved && (palmNear || !handsSeen)) {
                lastHeldEvidence = now
                reason = s.heldByPlatform ? "held (platform)" : input ? "held (input)" : "held (moving)"
            } else {
                let handAway = handsSeen && !palmNear
                show = now - lastHeldEvidence > (handAway ? 1.0 : Self.showAfter)
                reason = show ? (handAway ? "resting (hand away)" : "resting (still)") : "settling"
            }
        } else {
            restPos = nil
            palmNear = false
            reason = sample == nil ? "no anchor" : "not position-tracked"
        }
        if show != visible {
            log.notice("[ghost] \(hand == 0 ? "left" : "right", privacy: .public): \(show ? "SHOWN" : "hidden", privacy: .public) (\(reason, privacy: .public))")
        }
        visible = show
        let step = dt / 0.2
        alpha = visible ? min(1, alpha + step) : max(0, alpha - step)
    }
}
