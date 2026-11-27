import RabbitEarsAPI
import RabbitEarsKit
import SwiftUI

/// A page pushed over the shell.
enum Route: Hashable {
    case item(Item.ID)
    case person(Person.ID)
    case artist(UID)
    case album(UID)
    case playlist(UID)
    case collection(UID)
    case occasion(ActiveOccasion)
    case nowPlaying
    case channel(UID)
    case video(UID)
}

/// Navigation shared by every browsing view: the tab, the pages over it, what is playing.
@MainActor
@Observable
final class Browser: VideoBrowser {
    var tab = ShellTab.home
    var path: [Route] = []
    var playing: PlayRequest? {
        didSet { if playing == nil { returns += 1 } }
    }
    /// The movies or tv station in the station player, which a tile tunes in to directly.
    var tuning: Station? {
        didSet { if tuning == nil { returns += 1 } }
    }
    /// Counts the players' closings and the server's live changes, so a
    /// screen showing watch state or what is on reads it again.
    private(set) var returns = 0

    func changed() { returns += 1 }

    func open(_ item: Item) { path.append(.item(item.id)) }
    func replace(with item: Item) { path.replaceTop(with: .item(item.id)) }
    func open(person id: Person.ID) { path.append(.person(id)) }
    func open(_ route: Route) { path.append(route) }
}

/// Follows the server's live events while the app is in view, loads again
/// what each says has changed, and shows the app's brief notices.
struct LiveUpdates: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    let catalog: CatalogModel?
    let playlists: PlaylistsModel?
    let browser: Browser

    func body(content: Content) -> some View {
        content
            .task(id: "\(catalog.map { ObjectIdentifier($0).hashValue } ?? 0)/\(scenePhase == .background)") {
                await model.followLive(catalog, inView: scenePhase != .background)
            }
            .onChange(of: model.live.watched) { browser.changed() }
            .onChange(of: model.live.stations) { browser.changed() }
            .onChange(of: model.live.playlists) {
                browser.changed()
                Task { await playlists?.load() }
            }
            .overlay(alignment: .bottom) {
                if let notice = model.live.notice {
                    Text(notice).font(.system(size: 29, weight: .semibold)).padding(.horizontal, 32)
                        .frame(height: 72).background(.black.opacity(0.8), in: .capsule).padding(.bottom, 80)
                }
            }
    }
}

struct MainView: View {
    @Environment(AppModel.self) private var model
    /// The system's Now Playing and remote commands; the app makes one.
    let center: SystemNowPlayingCenter
    @State private var catalog: CatalogModel?
    @State private var music: MusicPlayer?
    /// Outlives every player: a new one knows no network path until its monitor first reports.
    @State private var capabilities = SystemCapabilities()
    @State private var playlists: PlaylistsModel?
    @State private var collections: CollectionsModel?
    @State private var stations: StationsModel?
    @State private var browser = Browser()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if let catalog {
                NavigationStack(path: $browser.path) {
                    ShellView()
                        .navigationDestination(for: Route.self) { route in
                            switch route {
                            case .item(let id): DetailView(id: id, capabilities: capabilities)
                            case .person(let id): PersonView(id: id)
                            case .artist(let id): ArtistView(id: id)
                            case .album(let id): AlbumView(id: id)
                            case .playlist(let id): PlaylistView(id: id)
                            case .collection(let id): CollectionView(id: id)
                            case .occasion(let occasion): OccasionView(occasion: occasion)
                            case .nowPlaying: NowPlayingView()
                            case .channel(let id): ChannelView(id: id)
                            case .video(let id): VideoDetailView(id: id, capabilities: capabilities)
                            }
                        }
                }
                .environment(catalog)
                .environment(music)
                .environment(playlists).environment(collections).environment(stations)
                .fullScreenCover(item: $browser.playing) { request in
                    if let client = model.client, let endpoint = model.endpoint, let profile = model.activeProfile {
                        HandoffGate(request: request, client: client, profileId: profile.id, browser: browser) {
                            browser.playing = nil
                        } player: {
                            PlayerScreen(
                                request: request, client: client, endpoint: endpoint, profileId: profile.id,
                                capabilities: capabilities, close: { browser.playing = nil }
                            )
                            .environment(catalog)
                        }
                        .environment(browser)
                        .environment(model)
                        // Rebuilt too for the answer to the handoff prompt, which plays the same title another way.
                        .id(HandoffGate<PlayerScreen>.identity(request))
                        .onAppear { Task { await music?.pause() } }
                    }
                }
                .alert(music?.alert ?? "", isPresented: alerting) { Button("OK") {} }
                .stationCover(browser: browser, music: music, capabilities: capabilities)
                .onChange(of: browser.playing == nil && browser.tuning == nil) { _, free in
                    // The remote drives the music only while no video or station is open.
                    if free { music?.attach(center) } else { music?.detach() }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.ground)
            }
        }
        .environment(browser)
        .modifier(LiveUpdates(catalog: catalog, playlists: playlists, browser: browser))
        // The profile too is read again on return, for a Hide kids' content changed on another device.
        .task(id: "\(model.activeProfile?.id.description ?? "")/\(scenePhase == .active)") {
            guard scenePhase == .active else { return }
            await model.reload()
            await model.loadLibrarySections()
        }
        // Hide kids' content, changed here or on another device, changes what the server lists.
        .onChange(of: model.activeProfile?.hideKidsContent == true) {
            Task {
                await catalog?.profileChanged(model.activeProfile)
                await collections?.load()
                await playlists?.load()
            }
        }
        .task(id: model.activeProfile?.id) {
            guard let client = model.client, let sync = model.sync, let endpoint = model.endpoint,
                let profile = model.activeProfile
            else { return }
            browser.path = []
            browser.tab = .home
            browser.tuning = nil
            await music?.stop()
            let player = MusicPlayer(
                client: client, endpoint: endpoint, profileId: profile.id, output: AVAudioOutput(),
                capabilities: capabilities)
            player.attach(center)
            music = player
            let lists = PlaylistsModel(
                client: client, replica: sync.replica, queue: sync.queue, profileId: profile.id,
                adult: profile.kind == .adult)
            playlists = lists
            collections = CollectionsModel(replica: sync.replica, queue: sync.queue, profileId: profile.id)
            stations = StationsModel(
                client: client, replica: sync.replica, queue: sync.queue, profileId: profile.id)
            let next = CatalogModel(
                client: client, replica: sync.replica, queue: sync.queue, profileId: profile.id,
                hidingKids: profile.hideKidsContent == true)
            catalog = next
            await next.load()
            await collections?.load()
            // A kid's Playlists tabs show only once something is shared with them.
            await lists.load()
        }
        .onDisappear { Task { await music?.stop() } }
    }

    private var alerting: Binding<Bool> {
        Binding(get: { music?.alert != nil }, set: { if !$0 { music?.alert = nil } })
    }
}

/// The top bar over the current tab. Moving focus along the bar switches
/// tabs, as the system tab bar does.
struct ShellView: View {
    @Environment(AppModel.self) private var model
    @Environment(CatalogModel.self) private var catalog
    @Environment(Browser.self) private var browser
    @FocusState private var focus: ShellTab?
    @State private var profileMenu = false
    @State private var settings = false

    var body: some View {
        ZStack(alignment: .top) {
            content
            HStack(spacing: 4) {
                ForEach(ShellTab.allCases.filter(shows), id: \.self) { tab in
                    Button {
                        browser.tab = tab
                    } label: {
                        HStack(spacing: 10) {
                            if tab == .search { Image(systemName: "magnifyingglass") }
                            Text(tab.title)
                        }
                    }
                    .buttonStyle(TabButtonStyle(current: tab == browser.tab))
                    .accessibilityIdentifier("section-\(tab)")
                    .focused($focus, equals: tab)
                }
            }
            .padding(6)
            .background(Theme.bar, in: .capsule)
            .focusSection()
            .frame(maxWidth: .infinity)
            .overlay(alignment: .trailing) {
                if let profile = model.activeProfile {
                    Button {
                        profileMenu = true
                    } label: {
                        Avatar(account: profile, size: 68)
                    }
                    .buttonStyle(AvatarButtonStyle())
                    .accessibilityLabel("Profile: \(profile.name)")
                }
            }
            .overlay(alignment: .leading) {
                if browser.tab == .music { NowPlayingChip() }
            }
            .padding(Theme.safeArea)
        }
        .background(Theme.ground)
        .ignoresSafeArea()
        .defaultFocus($focus, browser.tab)
        .onChange(of: focus) { if let focus { browser.tab = focus } }
        .onChange(of: model.librarySections) { if !shows(browser.tab) { browser.tab = .home } }
        .confirmationDialog(model.activeProfile?.name ?? "", isPresented: $profileMenu) {
            Button("Switch profile") { Task { await model.switchProfile() } }
            if model.activeProfile?.kind == .adult { Button("Settings") { settings = true } }
            Button("Sign out", role: .destructive) { Task { await model.signOut() } }
        }
        .fullScreenCover(isPresented: $settings) { SettingsView() }
        .toolbar(.hidden, for: .navigationBar)
    }

    private func shows(_ tab: ShellTab) -> Bool {
        tab.library.map { model.librarySections.contains($0) } ?? true
    }

    @ViewBuilder
    private var content: some View {
        if catalog.loaded, let error = catalog.error, catalog.catalog.items.isEmpty {
            VStack(spacing: 30) {
                Text("Can't load the library").font(.system(size: 48, weight: .bold))
                Text(error).font(.system(size: 30)).foregroundStyle(Theme.secondary)
                Button("Try again") { Task { await catalog.load() } }.buttonStyle(TVButtonStyle())
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !catalog.loaded {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            switch browser.tab {
            case .home: HomeView()
            case .tv: GridView(kind: .show)
            case .movies: GridView(kind: .movie)
            case .search: SearchView()
            case .music: MusicScreen()
            case .youTube: YouTubeScreen()
            }
        }
    }
}

/// Space the top bar takes over a tab's content.
let shellTop: CGFloat = 168
