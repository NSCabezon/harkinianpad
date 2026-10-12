import SwiftUI
import RealityKit

/// S0 stereo spike: a 16:9 plane in a window whose ShaderGraph material
/// (StereoMaterial.usda, CameraIndexSwitch) shows `left` to camera index 0 and
/// `right` to camera index 1. The simulator renders one view only (mono input
/// of the switch = left texture, red).
struct StereoSpikeView: View {
    @State private var presenter: StereoPresenter?
    @State private var status = "Cargando material…"
    @State private var fps = 0
    @State private var dropped = 0
    @Environment(\.physicalMetrics) private var metrics

    var body: some View {
        GeometryReader3D { proxy in
            RealityView { content in
                do {
                    let presenter = try StereoPresenter()
                    var material = try await ShaderGraphMaterial(
                        named: "/Root/StereoMaterial", from: "StereoMaterial.usda", in: Bundle.main)
                    try material.setParameter(name: "LeftTexture", value: .textureResource(presenter.leftResource))
                    try material.setParameter(name: "RightTexture", value: .textureResource(presenter.rightResource))
                    let plane = ModelEntity(
                        mesh: .generatePlane(width: 1, height: 9.0 / 16.0),
                        materials: [material])
                    plane.name = "StereoPlane"
                    content.add(plane)
                    presenter.start()
                    self.presenter = presenter
                    status = "CameraIndexSwitch OK"
                } catch {
                    status = "Error: \(error)"
                }
            } update: { content in
                // Fit the 1 m-wide plane to the window width.
                guard let plane = content.entities.first(where: { $0.name == "StereoPlane" }) else { return }
                let widthM = Float(metrics.convert(proxy.size.width, to: .meters))
                plane.scale = SIMD3(repeating: widthM)
            }
        }
        .overlay(alignment: .bottomLeading) {
            Text("\(status) · \(fps) fps · drop \(dropped)")
                .font(.caption.monospacedDigit())
                .padding(8)
                .glassBackgroundEffect()
                .padding()
        }
        .task {
            // Once per second: frames that reached replace(using:) on main.
            var last = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let presenter else { continue }
                fps = presenter.presentedFrames - last
                last = presenter.presentedFrames
                dropped = presenter.producer.droppedFrames.withLock { $0 }
            }
        }
        .onDisappear { presenter?.stop() }
    }
}
