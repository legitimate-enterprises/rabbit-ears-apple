import AppKit
import RabbitEarsAPI
import RabbitEarsKit
import SwiftUI

/// Closing the main window leaves the app running in the Dock; Cmd-Q quits.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

/// What outlives the main window, so it opens again as the app is.
@MainActor
@Observable
final class MainWindowState {
    /// The profile's music, playing on with the window closed.
    private(set) var music: MusicPlayer?
    /// The music player's output, so the volume slider reaches it.
    private(set) var audio: AVAudioOutput?
    private(set) var musicProfile: UID?
    /// The active adult's Preferences sheet, from the profile menu or the app menu.
    var showingPreferences = false

    func keep(_ music: MusicPlayer, _ audio: AVAudioOutput, for profile: UID) {
        self.music = music
        self.audio = audio
        musicProfile = profile
    }

    func endMusic() async {
        let ending = music
        music = nil
        audio = nil
        musicProfile = nil
        await ending?.stop()
    }
}

extension AppModel {
    var offersPreferences: Bool { phase == .browsing && isAdult }
}

/// Preferences… in the app menu, where Settings… would be, opening the main window if it is closed.
struct PreferencesCommands: Commands {
    let model: AppModel
    let app: MainWindowState
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Preferences…") {
                app.showingPreferences = true
                openWindow(id: "main")
            }
            .keyboardShortcut(",")
            .disabled(!model.offersPreferences)
        }
    }
}
