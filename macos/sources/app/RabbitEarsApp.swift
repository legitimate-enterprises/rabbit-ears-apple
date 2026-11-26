import RabbitEarsKit
import SwiftUI

@main
struct RabbitEarsApp: App {
    @State private var model: AppModel
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
            cache: ResponseCache())
        _model = State(initialValue: model)
        // The system's command center is process-wide, so the app makes the one center.
        _nowPlaying = State(initialValue: SystemNowPlayingCenter { await model.artwork?.data($0, .poster) })
    }

    var body: some Scene {
        // One window: the model and its player belong to the app, so a second window would drive the same playback.
        Window(model.serverName, id: "main") {
            RootView(nowPlaying: nowPlaying)
                .environment(model)
                .frame(minWidth: 900, minHeight: 600)
                .background(Theme.ground)
                .preferredColorScheme(.dark)
                .tint(Theme.amber)
                .task { await model.restore() }
        }
        .defaultSize(width: 1200, height: 760)
        .commands { NavigationCommands() }
        .windowToolbarStyle(.unified)
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    let nowPlaying: SystemNowPlayingCenter

    var body: some View {
        switch model.phase {
        case .starting: ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
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
