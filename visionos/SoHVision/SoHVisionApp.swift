import SwiftUI

@main
struct SoHVisionApp: App {
    @State private var cinemaStyle: ImmersionStyle = .full

    var body: some Scene {
        WindowGroup(id: AppModel.windowID) {
            GameView()
        }
        .defaultSize(width: 1280, height: 720)

        // "Cine": the game on a large world-anchored stereo screen, room replaced.
        ImmersiveSpace(id: AppModel.cinemaID) {
            CinemaView()
        }
        .immersionStyle(selection: $cinemaStyle, in: .full)
    }
}
