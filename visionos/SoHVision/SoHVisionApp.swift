import SwiftUI

@main
struct SoHVisionApp: App {
    var body: some Scene {
        WindowGroup {
            GameView()
        }
        .defaultSize(width: 1280, height: 720)
    }
}
