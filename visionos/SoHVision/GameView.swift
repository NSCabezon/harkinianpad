import SwiftUI
import GameController

/// Hosts the game. For now a placeholder that proves the window and the
/// controller path; the Metal surface the engine renders into replaces it.
struct GameView: View {
    @State private var controllerName: String?
    // Launch with `-StereoSpike YES` to open straight into the S0 spike.
    @State private var showStereoSpike = UserDefaults.standard.bool(forKey: "StereoSpike")

    var body: some View {
        Group {
            if showStereoSpike {
                StereoSpikeView()
            } else {
                VStack(spacing: 16) {
                    Text("Ship of Harkinian")
                        .font(.extraLargeTitle)
                    Text(controllerName.map { "Mando: \($0)" } ?? "Conecta un mando")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ornament(attachmentAnchor: .scene(.bottom)) {
            Toggle("Stereo test", isOn: $showStereoSpike)
                .toggleStyle(.button)
                .padding()
                .glassBackgroundEffect()
        }
        // Without this, visionOS routes a connected gamepad to the system
        // pointer and the sticks and face buttons never reach the app.
        .handlesGameControllerEvents(matching: .gamepad)
        .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidConnect)) { _ in refresh() }
        .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidDisconnect)) { _ in refresh() }
        .onAppear(perform: refresh)
    }

    private func refresh() {
        controllerName = GCController.controllers()
            .first { $0.extendedGamepad != nil && $0.productCategory != GCProductCategorySpatialController }?
            .vendorName
    }
}
