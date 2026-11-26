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
            rememberProfileByDefault: false, cache: ResponseCache())
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
        switch model.phase {
        case .starting: ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.ground)
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
