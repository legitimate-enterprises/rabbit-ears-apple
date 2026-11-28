import RabbitEarsKit
import SwiftUI

@main
struct RabbitEarsApp: App {
    @State private var model: AppModel
    @State private var center: SystemNowPlayingCenter

    init() {
        // Artwork revalidates by ETag from here across launches; the default is too small to hold a library.
        URLCache.shared = URLCache(memoryCapacity: 32 << 20, diskCapacity: 512 << 20)
        let model = AppModel(
            store: KeychainCredentialStore(), deviceName: UIDevice.current.name, platform: .tvos,
            rememberProfileByDefault: false, replicaDirectory: Replica.defaultDirectory)
        _model = State(initialValue: model)
        _center = State(initialValue: SystemNowPlayingCenter(artwork: { await model.artwork?.data($0, .poster) }))
    }

    var body: some Scene {
        WindowGroup {
            RootView(center: center)
                .environment(model)
                .preferredColorScheme(.dark)
                .tint(Theme.amber)
                .task { await model.restore() }
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    let center: SystemNowPlayingCenter

    var body: some View {
        // The splash fades into whatever the launch opens on.
        ZStack { screen }.animation(.easeInOut(duration: 0.4), value: model.phase == .starting)
    }

    @ViewBuilder private var screen: some View {
        switch model.phase {
        case .starting: Splash()
        case .unreachable:
            AccountPage(name: model.serverName) {
                VStack(alignment: .leading, spacing: 24) {
                    Text("Can't reach your server").font(.system(size: 64, weight: .bold))
                    Text(model.lastServer).font(.system(size: 30)).foregroundStyle(Theme.secondary)
                    HStack(spacing: 28) {
                        Button("Try again") { Task { await model.restore() } }.buttonStyle(TVButtonStyle(primary: true))
                        Button("Sign out") { Task { await model.signOut() } }.buttonStyle(TVButtonStyle())
                    }
                    .padding(.top, 20)
                }
                .padding(.leading, 120).padding(.top, 140)
            }
        case .signedOut: SignInFlow()
        case .choosingHousehold: HouseholdChoiceView()
        case .choosingProfile: WhoView()
        case .browsing: MainView(center: center)
        }
    }
}

/// From launch until the replica holds what this build reads.
struct Splash: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 40) {
            RabbitEarsMark().stroke(Theme.amber, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .frame(width: 90, height: 104)
            if model.libraryUpdate == .unreachable {
                Text("Your library needs an update, and the server can't be reached.")
                    .font(.system(size: 30)).foregroundStyle(Theme.secondary).multilineTextAlignment(.center)
                HStack(spacing: 28) {
                    Button("Try again") { Task { await model.retryLibraryUpdate() } }
                        .buttonStyle(TVButtonStyle(primary: true))
                    Button("Sign out") { Task { await model.signOut() } }.buttonStyle(TVButtonStyle())
                }
            } else {
                ProgressView()
                // Said only once an update takes more than a moment.
                Text("Updating your library…").font(.system(size: 30)).foregroundStyle(Theme.secondary)
                    .opacity(model.libraryUpdate == .updating ? 1 : 0)
                    .animation(.easeIn.delay(1), value: model.libraryUpdate)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.ground)
    }
}
