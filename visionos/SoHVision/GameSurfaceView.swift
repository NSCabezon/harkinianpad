import SwiftUI
import UIKit
import Metal
import QuartzCore

/// The engine's flat game surface: a CAMetalLayer-backed view. The game thread hands
/// each finished frame to a one-eye HPStereoSink ring (never blocking on a drawable);
/// the main thread presents the newest one on the display clock (HPVisionHost
/// setDisplayTickHandler), which also paces the engine.
struct GameSurfaceView: UIViewRepresentable {
    func makeUIView(context: Context) -> GameSurfaceUIView {
        GameSurfaceUIView(frame: .zero)
    }

    func updateUIView(_ uiView: GameSurfaceUIView, context: Context) {}

    static func dismantleUIView(_ uiView: GameSurfaceUIView, coordinator: ()) {
        uiView.detach()
    }
}

final class GameSurfaceUIView: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }

    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }
    private let queue: MTLCommandQueue?
    private var sink: HPStereoSink?

    override init(frame: CGRect) {
        let device = MTLCreateSystemDefaultDevice()
        queue = device?.makeCommandQueue()
        queue?.label = "soh.flat.present"
        super.init(frame: frame)
        backgroundColor = .black
        isOpaque = true

        let layer = metalLayer
        layer.device = device
        layer.pixelFormat = .bgra8Unorm // engine output is BGRA8 (sRGB variant handled in the shader)
        layer.framebufferOnly = false
        layer.maximumDrawableCount = 3
        layer.presentsWithTransaction = false
        layer.isOpaque = true

        registerForTraitChanges([UITraitDisplayScale.self]) { (view: GameSurfaceUIView, _) in
            view.setNeedsLayout()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if let scene = window?.windowScene {
            if let sink { HPVisionHost.attachStereo(sink) }
            HPVisionHost.setDisplayTickHandler { [weak self] in
                MainActor.assumeIsolated { self?.presentLatest() }
            }
            // Keep the 16:9 aspect while the person resizes the window.
            scene.requestGeometryUpdate(.Vision(resizingRestrictions: .uniform))
            setNeedsLayout()
        } else {
            detach()
        }
    }

    func detach() {
        if let sink { HPVisionHost.detachStereo(sink) }
        HPVisionHost.setDisplayTickHandler(nil)
    }

    /// Display tick (main thread): the newest finished frame, if any, to the layer.
    private func presentLatest() {
        guard let sink, let queue else { return }
        sink.presentLatest(to: metalLayer, queue: queue)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let scale = traitCollection.displayScale > 0 ? traitCollection.displayScale : 2
        contentScaleFactor = scale
        metalLayer.contentsScale = scale
        let size = CGSize(width: (bounds.width * scale).rounded(), height: (bounds.height * scale).rounded())
        guard size.width >= 1, size.height >= 1 else { return }
        if metalLayer.drawableSize != size {
            metalLayer.drawableSize = size
            HP_SetViewSize(Int32(size.width), Int32(size.height))
            // Ring at the engine render size (= drawable size).
            if let device = metalLayer.device,
               let newSink = HPStereoSink(device: device, width: Int(size.width), height: Int(size.height), eyes: 1) {
                if let sink { HPVisionHost.detachStereo(sink) }
                sink = newSink
                if window != nil { HPVisionHost.attachStereo(newSink) }
            }
        }
    }
}
