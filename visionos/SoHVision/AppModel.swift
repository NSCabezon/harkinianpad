import SwiftUI

/// View state shared by the game window and the cinema space. It outlives the
/// window, which is closed while the cinema is open and reopened afterwards.
@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    static let windowID = "game"
    static let cinemaID = "cinema"

    enum Cinema { case closed, opening, open }

    var cinema: Cinema = .closed
    /// The game window is on screen (it is dismissed while the cinema is open).
    var windowOpen = false
    // Launch with `-StereoGame YES` to start in the 3D (stereo) view.
    var stereoGame = UserDefaults.standard.bool(forKey: "StereoGame")
    // FPS meter; off by default (`-ShowFPS YES` turns it on at launch).
    var showFPS = UserDefaults.standard.bool(forKey: "ShowFPS")

    private init() {}
}
