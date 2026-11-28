import RabbitEarsKit
import SwiftUI

@main
struct RabbitEarsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model: AppModel
    @State private var app = MainWindowState()
    @State private var nowPlaying: SystemNowPlayingCenter

    init() {
        // Artwork revalidates by ETag from here across launches; the default is too small to hold a library.
        URLCache.shared = URLCache(memoryCapacity: 32 << 20, diskCapacity: 512 << 20)
        let store = KeychainCredentialStore()
        // The UI test starts from Sign in whatever this Mac remembers.
        if CommandLine.arguments.contains("--signed-out") { store.token = nil }
        let capabilities = SystemCapabilities()
        let downloads = DownloadStore(downloader: URLSessionDownloader(), facts: { capabilities.facts() })
        let model = AppModel(
            store: store, deviceName: Host.current().localizedName ?? "Mac", downloads: downloads,
            replicaDirectory: Replica.defaultDirectory)
        _model = State(initialValue: model)
        // The system's command center is process-wide, so the app makes the one center.
        _nowPlaying = State(initialValue: SystemNowPlayingCenter { await model.artwork?.data($0, .poster) })
        // Once per launch, not per window: the window opened again keeps the profile it closed on.
        Task { await model.restore() }
    }

    var body: some Scene {
        // One window: the model and its player belong to the app, so a second window would drive the same playback.
        Window(model.serverName, id: "main") {
            RootView(nowPlaying: nowPlaying)
                .environment(model)
                .environment(app)
                .frame(minWidth: 900, minHeight: 600)
                .background(Theme.ground)
                .preferredColorScheme(.dark)
                .tint(Theme.amber)
        }
        .defaultSize(width: 1200, height: 760)
        .commands {
            NavigationCommands()
            PreferencesCommands(model: model, app: app)
        }
        .windowToolbarStyle(.unified)
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    let nowPlaying: SystemNowPlayingCenter

    var body: some View {
        // The splash fades into whatever the launch opens on.
        ZStack { screen }.animation(.easeInOut(duration: 0.4), value: model.phase == .starting)
    }

    @ViewBuilder private var screen: some View {
        switch model.phase {
        case .starting: Splash()
        case .unreachable:
            ContentUnavailableView {
                Label("Can't reach the server", systemImage: "wifi.exclamationmark")
            } description: {
                Text(model.lastServer)
            } actions: {
                Button("Try again") { Task { await model.restore() } }.buttonStyle(SecondaryButtonStyle())
                Button("Sign out") { Task { await model.signOut() } }.buttonStyle(.plain)
                    .foregroundStyle(Theme.secondary)
            }
            .background(Theme.ground)
        case .signedOut: SignInFlow()
        case .choosingHousehold: HouseholdChoiceView()
        case .choosingProfile: WhosWatchingView()
        case .browsing: MainView(nowPlaying: nowPlaying)
        }
    }
}

/// From launch until the replica holds what this build reads.
struct Splash: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 24) {
            StationGlyph(size: 56)
            if model.libraryUpdate == .unreachable {
                Text("Your library needs an update, and the server can't be reached.")
                    .font(.system(size: 13)).foregroundStyle(Theme.secondary).multilineTextAlignment(.center)
                Button("Try again") { Task { await model.retryLibraryUpdate() } }.buttonStyle(SecondaryButtonStyle())
                Button("Sign out") { Task { await model.signOut() } }.buttonStyle(.plain)
                    .foregroundStyle(Theme.secondary)
            } else {
                ProgressView().controlSize(.small)
                // Said only once an update takes more than a moment.
                Text("Updating your library…").font(.system(size: 13)).foregroundStyle(Theme.secondary)
                    .opacity(model.libraryUpdate == .updating ? 1 : 0)
                    .animation(.easeIn.delay(1), value: model.libraryUpdate)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.ground)
    }
}
