import SwiftUI
import UIKit
import Metal
import QuartzCore

/// The engine's flat game surface: a CAMetalLayer-backed view the presenter
/// (HPVisionHost.m, game thread) draws each finished frame into.
struct GameSurfaceView: UIViewRepresentable {
    func makeUIView(context: Context) -> GameSurfaceUIView {
        GameSurfaceUIView(frame: .zero)
    }

    func updateUIView(_ uiView: GameSurfaceUIView, context: Context) {}

    static func dismantleUIView(_ uiView: GameSurfaceUIView, coordinator: ()) {
        HPVisionHost.attach(nil)
    }
}

final class GameSurfaceUIView: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }

    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        isOpaque = true

        let layer = metalLayer
        layer.device = MTLCreateSystemDefaultDevice()
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
            HPVisionHost.attach(metalLayer)
            // Keep the 16:9 aspect while the person resizes the window.
            scene.requestGeometryUpdate(.Vision(resizingRestrictions: .uniform))
            setNeedsLayout()
        } else {
            HPVisionHost.attach(nil)
        }
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
        }
    }
}
