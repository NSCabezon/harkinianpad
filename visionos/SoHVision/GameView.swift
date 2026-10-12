import SwiftUI
import GameController

/// Hosts the game: the engine's Metal surface, started once on first appearance.
/// The ornament switches between the flat surface ("2D", default) and the
/// RealityKit stereo plane ("3D", S5), and swaps in the S0 spike ("Stereo test").
/// "Cine" opens the cinema space (CinemaView) and closes this window until it ends.
struct GameView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissWindow) private var dismissWindow
    // Launch with `-StereoSpike YES` to open straight into the S0 spike.
    @State private var showStereoSpike = UserDefaults.standard.bool(forKey: "StereoSpike")
    @State private var model = AppModel.shared
    @State private var engineError: String?

    var body: some View {
        Group {
            if showStereoSpike {
                StereoSpikeView()
            } else {
                Group {
                    if model.cinema != .closed {
                        // The cinema presents the game; nothing may attach a sink here.
                        Text("Modo Cine").font(.title).foregroundStyle(.secondary)
                    } else if model.stereoGame {
                        StereoGameView()
                    } else {
                        GameSurfaceView()
                            .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    }
                }
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
            HStack(spacing: 16) {
                Picker("Vista", selection: $model.stereoGame) {
                    Text("2D").tag(false)
                    Text("3D").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 160)
                .disabled(showStereoSpike || model.cinema != .closed)
                Button("Cine", systemImage: "theatermasks", action: openCinema)
                    .disabled(showStereoSpike || model.cinema != .closed)
                Toggle("Stereo test", isOn: $showStereoSpike)
                    .toggleStyle(.button)
                Toggle("FPS", isOn: $model.showFPS)
                    .toggleStyle(.button)
            }
            .padding()
            .glassBackgroundEffect()
        }
        // An ornament, not an overlay: the 3D plane sits in front of the window surface.
        .ornament(visibility: model.showFPS ? .visible : .hidden, attachmentAnchor: .scene(.top), contentAlignment: .bottom) {
            FPSBadge(monitor: PerfMonitor.shared)
        }
        // Without this, visionOS routes a connected gamepad to the system
        // pointer and the sticks and face buttons never reach the app.
        .handlesGameControllerEvents(matching: .gamepad)
        .onChange(of: scenePhase, initial: true) { updateActive() }
        .onChange(of: showStereoSpike) { updateActive() }
        .onChange(of: model.stereoGame) { updateActive() }
        .onChange(of: model.cinema) { updateActive() }
        .onAppear { model.windowOpen = true }
        .onDisappear { model.windowOpen = false }
        .onReceive(NotificationCenter.default.publisher(for: .HPVisionHostEngineDidStop)) { _ in
            refreshEngineError()
        }
    }

    private func startEngine() {
        PerfMonitor.shared.start()
        if !HPVisionHost.startEngine() {
            refreshEngineError()
        }
        updateActive() // startEngine resets the eye count to 1 on first start
        // Launch with `-StartCinema YES` to open the cinema right away (once).
        if UserDefaults.standard.bool(forKey: "StartCinema") {
            UserDefaults.standard.removeObject(forKey: "StartCinema")
            openCinema()
        }
    }

    /// Opens the cinema space; this window closes once it is up (CinemaView
    /// reopens it on the way out).
    private func openCinema() {
        guard model.cinema == .closed else { return }
        model.cinema = .opening
        Task {
            switch await openImmersiveSpace(id: AppModel.cinemaID) {
            case .opened:
                dismissWindow(id: AppModel.windowID)
            default:
                model.cinema = .closed
            }
        }
    }

    /// The engine only renders while the scene is active and its surface is shown;
    /// it renders both eyes only while the stereo view is shown.
    /// While the cinema is up it owns these (CinemaView).
    private func updateActive() {
        guard model.cinema == .closed else { return }
        HP_SetActive(scenePhase == .active && !showStereoSpike ? 1 : 0)
        HP_SetEyeCount(model.stereoGame && !showStereoSpike ? 2 : 1)
        PerfMonitor.shared.setMode(model.stereoGame ? "3D" : "2D")
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

/// Compact FPS meter (PerfMonitor, refreshed once per second).
struct FPSBadge: View {
    let monitor: PerfMonitor

    var body: some View {
        let s = monitor.sample
        let stereo = monitor.mode != "2D"
        VStack(alignment: .leading, spacing: 2) {
            Text("\(monitor.mode) · \(s.eyes) eye\(s.eyes == 1 ? "" : "s") · \(s.width)×\(s.height)")
            Text("game \(s.gameFps, specifier: "%.1f") fps")
            Text(stereo
                 ? "replace \(s.presentFps, specifier: "%.1f")/s · drop \(s.dropped)"
                 : "present \(s.presentFps, specifier: "%.1f")/s")
            Text("cpu \(s.cpuAvgMs, specifier: "%.2f") / \(s.cpuMaxMs, specifier: "%.2f") ms")
            Text("audio q \(s.audioQueued) · underruns \(s.audioUnderruns)")
        }
        .font(.caption.monospacedDigit())
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassBackgroundEffect(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
