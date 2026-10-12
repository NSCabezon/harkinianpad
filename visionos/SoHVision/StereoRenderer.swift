import Foundation
import Metal
import RealityKit
import os

// S0 stereo spike: background producer + main-actor presenter.
//
// Threading answer (from the visionOS 27 SDK RealityFoundation.swiftinterface):
// `LowLevelTexture` is a `@MainActor` class and `replace(using:)` is
// MainActor-isolated, so it cannot be called from the render thread (the
// compiler rejects it; `MainActor.assumeIsolated` would trap). The handoff is:
//
//   producer thread (90 Hz)                       main actor
//   ───────────────────────                       ──────────
//   wait(slot free)
//   encode game/pattern -> staging[slot][eye]
//   signal sharedEvent = frame; commit  ──hop──▶  cmd.encodeWaitForEvent(frame)
//                                                 dst = llt[eye].replace(using: cmd)
//                                                 blit staging[slot][eye] -> dst
//                                                 commit; on completion free slot
//
// The main actor only *encodes* (no CPU wait on the GPU): the MTLSharedEvent
// orders the blit after the producer's work even on a different queue, and a
// 3-slot ring (DispatchSemaphore) keeps the producer from overwriting a slot the
// blit has not consumed. Cost: one extra blit per eye per frame.

struct StereoFrameHandoff: Sendable {
    let frame: UInt64
    let slot: Int
}

private struct StereoPatternParams {
    var time: Float
    var disparity: Float
    var eye: UInt32
}

/// Owns the Metal objects shared by both sides. Immutable after init except the
/// producer-queue-only state, hence `@unchecked Sendable`.
final class StereoProducer: @unchecked Sendable {
    static let slotCount = 3
    let width: Int
    let height: Int

    let device: MTLDevice
    let event: MTLSharedEvent
    /// staging[slot][eye]
    let staging: [[MTLTexture]]
    let slotsFree = DispatchSemaphore(value: StereoProducer.slotCount)

    private let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private let producerQueue = DispatchQueue(label: "soh.stereo.producer", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    // Producer-queue-only state.
    private var frame: UInt64 = 0
    private let start = Date()
    private let log = Logger(subsystem: "SoHVision", category: "Stereo")

    let droppedFrames = OSAllocatedUnfairLock(initialState: 0)

    init(width: Int, height: Int) throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let event = device.makeSharedEvent(),
              let library = device.makeDefaultLibrary(),
              let fn = library.makeFunction(name: "stereoPattern")
        else { throw StereoError.metalSetup }
        self.width = width
        self.height = height
        self.device = device
        self.queue = queue
        self.event = event
        self.pipeline = try device.makeComputePipelineState(function: fn)

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        desc.usage = [.shaderWrite, .shaderRead]
        desc.storageMode = .private
        var slots: [[MTLTexture]] = []
        for _ in 0..<Self.slotCount {
            var eyes: [MTLTexture] = []
            for _ in 0..<2 {
                guard let t = device.makeTexture(descriptor: desc) else { throw StereoError.metalSetup }
                eyes.append(t)
            }
            slots.append(eyes)
        }
        self.staging = slots
    }

    /// Starts the 90 Hz producer. `deliver` is invoked on the producer queue
    /// after the frame is committed; it must hop to the main actor itself.
    func start(deliver: @escaping @Sendable (StereoFrameHandoff) -> Void) {
        let t = DispatchSource.makeTimerSource(flags: .strict, queue: producerQueue)
        t.schedule(deadline: .now(), repeating: .nanoseconds(1_000_000_000 / 90), leeway: .microseconds(500))
        t.setEventHandler { [weak self] in self?.tick(deliver: deliver) }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func tick(deliver: @Sendable (StereoFrameHandoff) -> Void) {
        dispatchPrecondition(condition: .notOnQueue(.main))
        // Never block the producer: if the presenter is behind, drop this frame.
        guard slotsFree.wait(timeout: .now()) == .success else {
            droppedFrames.withLock { $0 += 1 }
            return
        }
        frame += 1
        let slot = Int(frame % UInt64(Self.slotCount))
        guard let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeComputeCommandEncoder()
        else { slotsFree.signal(); return }
        cmd.label = "stereo.produce.\(frame)"
        enc.setComputePipelineState(pipeline)
        let time = Float(Date().timeIntervalSince(start))
        for eye in 0..<2 {
            var p = StereoPatternParams(time: time, disparity: 0.04, eye: UInt32(eye))
            enc.setTexture(staging[slot][eye], index: 0)
            enc.setBytes(&p, length: MemoryLayout<StereoPatternParams>.stride, index: 0)
            let tg = MTLSize(width: 16, height: 16, depth: 1)
            let grid = MTLSize(width: (width + 15) / 16, height: (height + 15) / 16, depth: 1)
            enc.dispatchThreadgroups(grid, threadsPerThreadgroup: tg)
        }
        enc.endEncoding()
        cmd.encodeSignalEvent(event, value: frame)
        cmd.commit()
        deliver(StereoFrameHandoff(frame: frame, slot: slot))
    }
}

enum StereoError: Error {
    case metalSetup
}

/// Main-actor side: owns the two `LowLevelTexture`s and does the per-frame
/// `replace(using:)` + blit.
@MainActor
final class StereoPresenter {
    let producer: StereoProducer
    let left: LowLevelTexture
    let right: LowLevelTexture
    let leftResource: TextureResource
    let rightResource: TextureResource
    private let queue: MTLCommandQueue
    private(set) var presentedFrames = 0
    private var lastFrame: UInt64 = 0

    init(width: Int = 1280, height: Int = 720) throws {
        let producer = try StereoProducer(width: width, height: height)
        guard let queue = producer.device.makeCommandQueue() else { throw StereoError.metalSetup }
        let desc = LowLevelTexture.Descriptor(
            textureType: .type2D, pixelFormat: .bgra8Unorm,
            width: width, height: height, depth: 1, mipmapLevelCount: 1,
            textureUsage: [.shaderRead, .shaderWrite])
        self.producer = producer
        self.queue = queue
        self.left = try LowLevelTexture(descriptor: desc)
        self.right = try LowLevelTexture(descriptor: desc)
        self.leftResource = try TextureResource(from: left)
        self.rightResource = try TextureResource(from: right)
    }

    func start() {
        producer.start { [weak self] handoff in
            // Hop: replace(using:) is MainActor-only.
            Task { @MainActor in self?.present(handoff) }
        }
    }

    func stop() { producer.stop() }

    private func present(_ h: StereoFrameHandoff) {
        // Stale frames (main was busy and several hops queued up) are skipped:
        // only the newest one is worth a blit.
        guard h.frame > lastFrame, let cmd = queue.makeCommandBuffer() else {
            producer.slotsFree.signal()
            return
        }
        lastFrame = h.frame
        cmd.label = "stereo.present.\(h.frame)"
        cmd.encodeWaitForEvent(producer.event, value: h.frame)
        guard let blit = cmd.makeBlitCommandEncoder() else {
            producer.slotsFree.signal()
            return
        }
        let targets = [left.replace(using: cmd), right.replace(using: cmd)]
        for eye in 0..<2 {
            blit.copy(from: producer.staging[h.slot][eye], to: targets[eye])
        }
        blit.endEncoding()
        let sem = producer.slotsFree
        cmd.addCompletedHandler { _ in sem.signal() }
        cmd.commit()
        presentedFrames += 1
    }
}
