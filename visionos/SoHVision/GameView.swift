import SwiftUI
import GameController

/// Hosts the game: the engine's Metal surface, started once on first appearance.
/// The "Stereo test" ornament swaps in the S0 spike.
struct GameView: View {
    @Environment(\.scenePhase) private var scenePhase
    // Launch with `-StereoSpike YES` to open straight into the S0 spike.
    @State private var showStereoSpike = UserDefaults.standard.bool(forKey: "StereoSpike")
    @State private var engineError: String?

    var body: some View {
        Group {
            if showStereoSpike {
                StereoSpikeView()
            } else {
                GameSurfaceView()
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.black)
                    .overlay(alignment: .center) {
                        if let engineError {
                            Text(engineError)
                                .font(.title3)
                                .padding()
                                .glassBackgroundEffect()
                        }
                    }
                    .onAppear(perform: startEngine)
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
        .onChange(of: scenePhase, initial: true) { updateActive() }
        .onChange(of: showStereoSpike) { updateActive() }
        .onReceive(NotificationCenter.default.publisher(for: .HPVisionHostEngineDidStop)) { _ in
            refreshEngineError()
        }
    }

    private func startEngine() {
        if !HPVisionHost.startEngine() {
            refreshEngineError()
        }
    }

    /// The engine only renders while the scene is active and its surface is shown.
    private func updateActive() {
        HP_SetActive(scenePhase == .active && !showStereoSpike ? 1 : 0)
    }

    private func refreshEngineError() {
        switch HPVisionHost.engineState {
        case .failed:
            engineError = "No se pudo arrancar el motor"
        case .exited:
            engineError = "El motor se detuvo (código \(HPVisionHost.engineExitCode))"
        default:
            engineError = nil
        }
    }
}
