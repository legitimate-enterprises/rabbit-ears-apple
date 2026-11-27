import RabbitEarsAPI
import RabbitEarsKit
import SwiftUI

extension AppModel {
    var isAdult: Bool { activeProfile?.kind == .adult }
    var musicModel: MusicModel? {
        guard let client, let sync, let activeProfile else { return nil }
        return MusicModel(client: client, replica: sync.replica, profileId: activeProfile.id)
    }

    var youtubeModel: YouTubeModel? {
        guard let client, let sync, let activeProfile else { return nil }
        return YouTubeModel(client: client, replica: sync.replica, queue: sync.queue, profileId: activeProfile.id)
    }
}

/// Follows the server's live events while the window is in view, loads again
/// what each says has changed, and shows the app's brief notices.
struct LiveUpdates: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    let catalog: CatalogModel?
    let stations: StationsModel?
    let playlists: PlaylistsModel?
    let browser: Browser

    func body(content: Content) -> some View {
        content
            .task(id: "\(catalog.map { ObjectIdentifier($0).hashValue } ?? 0)/\(scenePhase == .background)") {
                await model.followLive(catalog, inView: scenePhase != .background)
            }
            .onChange(of: model.live.watched) { browser.revision += 1 }
            .onChange(of: model.live.stations) {
                browser.revision += 1
                if model.activeProfile?.kind == .adult { Task { await stations?.loadMine() } }
            }
            .onChange(of: model.live.playlists) {
                browser.revision += 1
                Task { await playlists?.load() }
            }
            .overlay(alignment: .bottom) {
                if let notice = model.live.notice {
                    Text(notice).font(.system(size: 13, weight: .semibold)).padding(.horizontal, 14)
                        .frame(height: 32).background(.black.opacity(0.8), in: .capsule).padding(.bottom, 28)
                }
            }
    }
}

extension View {
    /// On each page, not around the stack: a pushed page fills the detail column over anything beside the stack.
    fileprivate func miniPlayer(_ music: MusicPlayer?, _ audio: AVAudioOutput?) -> some View {
        frame(maxWidth: .infinity, maxHeight: .infinity).safeAreaInset(edge: .bottom, spacing: 0) {
            if let music, let audio { MiniPlayer(audio: audio).environment(music) }
        }
    }
}

struct MainView: View {
    @Environment(AppModel.self) private var model
    let nowPlaying: SystemNowPlayingCenter
    /// Hands each profile's player to a test, which has no other way to play.
    var entered: (MusicPlayer) -> Void = { _ in }
    @State private var section = SidebarSection.home
    @State private var catalog: CatalogModel?
    @State private var music: MusicPlayer?
    /// Outlives every player: a new one knows no network path until its monitor first reports.
    @State private var capabilities = SystemCapabilities()
    @State private var playlists: PlaylistsModel?
    @State private var collections: CollectionsModel?
    @State private var stations: StationsModel?
    @State var browser = Browser()
    @State private var search = ""
    @FocusState private var searchFocused: Bool
    /// The name a playlist or station shown at the root gives itself, for the back button.
    @State private var rootTitle: String?
    @State private var prompt = DownloadPrompt()
    @Environment(\.scenePhase) private var scenePhase
    /// The music player's output, so the volume slider reaches it.
    @State private var audio: AVAudioOutput?

    var body: some View {
        ZStack {
            NavigationSplitView {
                sidebar
            } detail: {
                NavigationStack(path: $browser.path) {
                    Group {
                        if let catalog, catalog.loaded {
                            content(catalog)
                        } else {
                            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                    .miniPlayer(music, audio)
                    .navigationDestination(for: Route.self) { route in
                        if let catalog {
                            RouteDestination(route: route, capabilities: capabilities)
                                .environment(catalog).environment(music).environment(playlists)
                                .environment(collections).environment(stations)
                                .page(route, in: browser, root: rootTitle ?? section.title)
                                .miniPlayer(music, audio)
                        }
                    }
                }
            }
            .searchable(text: $search, placement: .toolbar, prompt: "Search")
            .searchFocused($searchFocused)
            .toolbar(browser.playing == nil && browser.tuning == nil ? .automatic : .hidden, for: .windowToolbar)
            if let request = browser.playing, let catalog, let client = model.client, let endpoint = model.endpoint,
                let profile = model.activeProfile
            {
                HandoffGate(request: request, client: client, profileId: profile.id, browser: browser) {
                    browser.playing = nil
                } player: {
                    PlayerScreen(
                        request: request, client: client, endpoint: endpoint, profileId: profile.id,
                        capabilities: capabilities, close: { browser.playing = nil }
                    )
                    .environment(catalog)
                }
                .id(HandoffGate<PlayerScreen>.identity(request))
            }
            if let station = browser.tuning, let client = model.client, let replica = model.sync?.replica,
                let endpoint = model.endpoint, let profile = model.activeProfile
            {
                StationPlayerScreen(
                    station: station, client: client, replica: replica, endpoint: endpoint, profileId: profile.id,
                    capabilities: capabilities, close: { browser.tuning = nil }
                )
                .id(station.id)
            }
        }
        .environment(browser)
        .downloadPrompt(prompt, store: model.downloads)
        // In view, the downloads catch up: watch changes made offline go up, then what is new comes down.
        .task(id: "\(model.activeProfile?.id ?? 0)/\(scenePhase == .active)") {
            guard scenePhase == .active, let profile = model.activeProfile?.id else { return }
            Task {
                // The profile too, for a Hide kids' content changed on another device.
                await model.reload()
                await model.loadLibrarySections()
            }
            await model.downloads?.sync(profile: profile)
        }
        // A title's menu shows which kids' lists hold it without asking per tile.
        .task(id: "\(model.activeProfile?.id ?? 0)/\(model.allowListKids.map(\.id))/\(scenePhase == .active)") {
            if scenePhase == .active { await model.loadAllowLists() }
        }
        .background(Theme.ground)
        .sheet(item: $browser.naming) { request in
            if let playlists { PlaylistNameSheet(request: request).environment(playlists) }
        }
        .sheet(
            item: $browser.sharing, onDismiss: { Task { await playlists?.load() } },
            content: { playlist in
                if let playlists {
                    PlaylistShareSheet(model: playlists.shares(of: playlist.id), name: playlist.name)
                }
            }
        )
        .confirmationDialog(
            "Delete “\(browser.deleting?.name ?? "")”?", isPresented: deleteBinding, titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let doomed = browser.deleting {
                    Task {
                        if await playlists?.delete(doomed) == false { browser.alert = playlists?.error }
                    }
                }
            }
        } message: {
            Text("Everything in it stays in your libraries.")
        }
        .editionQuestion(playlists)
        .imageSheet(browser: browser, client: playlists?.client ?? stations?.client, playlists: playlists)
        .sheet(item: $browser.editingStation) { request in
            if let stations {
                StationEditor(request: request).environment(stations).environment(playlists).environment(browser)
            }
        }
        .rescheduleQuestion($browser.rescheduling, stations) { browser.revision += 1 }
        .modifier(LiveUpdates(catalog: catalog, stations: stations, playlists: playlists, browser: browser))
        .alert(
            browser.alert ?? "",
            isPresented: Binding(get: { browser.alert != nil }, set: { if !$0 { browser.alert = nil } })
        ) {
            Button("OK") { browser.alert = nil }
        }
        .sheet(item: $browser.namingCollection) { request in
            if let collections { CollectionNameSheet(request: request).environment(collections) }
        }
        .confirmationDialog(
            "Delete “\(browser.deletingCollection?.name ?? "")”?", isPresented: deleteCollectionBinding,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let doomed = browser.deletingCollection {
                    browser.path.removeAll { $0 == .collection(doomed.id) }
                    Task { await collections?.delete(doomed) }
                }
            }
        } message: {
            Text("Its movies stay in your libraries.")
        }
        .onChange(of: section) { browser.history.reset() }
        .onChange(of: browser.playing == nil && browser.tuning == nil) { _, free in
            // Video and music share the speakers and the system's transport; a video or station takes both.
            guard let music else { return }
            if free { return music.attach(nowPlaying) }
            music.detach()
            Task { await music.pause() }
        }
        .onChange(of: playlists?.playlists) {
            if case .playlist(let id) = section, playlists?.playlists.contains(where: { $0.id == id }) == false {
                section = .home
            }
        }
        .onChange(of: model.librarySections) { if !shows(section) { section = .home } }
        .onChange(of: stations?.mine) {
            if case .station(let id) = section, stations?.mine.contains(where: { $0.id == id }) == false {
                section = .home
            }
        }
        .navigation(navigator)
        .onReceive(NotificationCenter.default.publisher(for: .playNext)) { note in
            if let id = note.object as? Item.ID, let catalog, let next = catalog.catalog.item(id) {
                browser.play(next, in: catalog.catalog, from: 0)
            }
        }
        .task(id: model.activeProfile?.id) { await enter() }
        // Hide kids' content, changed here or on another device, changes what the server lists.
        .onChange(of: model.activeProfile?.hideKidsContent == true) {
            Task {
                await catalog?.profileChanged(model.activeProfile)
                await collections?.load()
                await playlists?.load()
            }
        }
        .onDisappear { Task { await music?.stop() } }
    }

    private func shows(_ section: SidebarSection) -> Bool {
        section.library.map { model.librarySections.contains($0) } ?? true
    }

    private var navigator: Navigator {
        Navigator(browser: browser, show: { section = $0 }, shows: shows, search: { searchFocused = true })
    }

    /// Builds what one profile browses with; a kid gets only the playlists shared with them and no
    /// stations of their own.
    private func enter() async {
        await music?.stop()
        music = nil
        playlists = nil
        collections = nil
        browser.tuning = nil
        guard let client = model.client, let sync = model.sync, let endpoint = model.endpoint,
            let profile = model.activeProfile
        else { return }
        let next = CatalogModel(
            client: client, replica: sync.replica, queue: sync.queue, profileId: profile.id,
            hidingKids: profile.hideKidsContent == true)
        catalog = next
        let sets = CollectionsModel(
            client: client, replica: sync.replica, queue: sync.queue, engine: sync.engine, profileId: profile.id)
        collections = sets
        let tuned = StationsModel(
            client: client, replica: sync.replica, queue: sync.queue, engine: sync.engine, profileId: profile.id)
        stations = tuned
        Task { await sets.load() }
        let output = AVAudioOutput()
        output.player.volume = Volume.stored
        audio = output
        let player = MusicPlayer(
            client: client, endpoint: endpoint, profileId: profile.id, output: output, capabilities: capabilities)
        player.attach(nowPlaying)
        music = player
        entered(player)
        let lists = PlaylistsModel(
            client: client, replica: sync.replica, queue: sync.queue, engine: sync.engine, profileId: profile.id,
            adult: profile.kind == .adult)
        playlists = lists
        Task { await lists.load() }
        if profile.kind == .adult {
            Task { await tuned.loadMine() }
        }
        await next.load()
    }

    private var deleteBinding: Binding<Bool> {
        Binding(get: { browser.deleting != nil }, set: { if !$0 { browser.deleting = nil } })
    }

    private var deleteCollectionBinding: Binding<Bool> {
        Binding(
            get: { browser.deletingCollection != nil }, set: { if !$0 { browser.deletingCollection = nil } })
    }

    private var sidebar: some View {
        List(selection: $section) {
            ForEach(SidebarSection.libraries.filter(shows), id: \.self) {
                Label($0.title, systemImage: $0.icon).tag($0)
            }
            if let playlists, !playlists.playlists.isEmpty || model.isAdult {
                Section {
                    ForEach(playlists.playlists, id: \.id) { playlist in
                        Text(playlist.name).tag(SidebarSection.playlist(playlist.id))
                            .contextMenu { PlaylistActions(playlist: playlist) }
                    }
                } header: {
                    Text("Playlists")
                }
            }
            if let stations, model.isAdult {
                Section {
                    ForEach(stations.mine) { station in
                        Text(station.name).tag(SidebarSection.station(station.id))
                    }
                } header: {
                    Text("Stations")
                }
            }
        }
        .safeAreaInset(edge: .bottom) { ProfileMenu().environment(catalog).padding(12) }
        .navigationSplitViewColumnWidth(210)
    }

    @ViewBuilder
    private func content(_ catalog: CatalogModel) -> some View {
        Group {
            if let error = catalog.error, catalog.catalog.items.isEmpty {
                ContentUnavailableView {
                    Label("Can't load the library", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(error)
                } actions: {
                    Button("Try again") { Task { await catalog.load() } }.buttonStyle(SecondaryButtonStyle())
                }
            } else {
                browse
            }
        }
        .environment(catalog)
        .environment(music)
        .environment(playlists)
        .environment(collections)
        .environment(stations)
        .navigationTitle(section.title)
        .onPreferenceChange(PageTitle.self) { title in MainActor.assumeIsolated { rootTitle = title } }
    }

    @ViewBuilder
    private var browse: some View {
        let searching = !search.trimmingCharacters(in: .whitespaces).isEmpty
        switch section {
        case .youtube: YouTubeScreen(search: search)
        case _ where searching: SearchView(search: search)
        case .stations: StationsScreen()
        case .music: MusicScreen()
        case .playlist(let id): PlaylistScreen(id: id)
        case .station(let id): StationScreen(id: id)
        case .home: HomeView()
        case .tv: GridView(kind: .show)
        case .movies: GridView(kind: .movie)
        }
    }
}

/// The screen a pushed route shows.
private struct RouteDestination: View {
    let route: Route
    let capabilities: SystemCapabilities

    var body: some View {
        switch route {
        case .item(let id): DetailView(id: id, capabilities: capabilities)
        case .person(let id): PersonView(id: id)
        case .video(let id): VideoScreen(id: id, capabilities: capabilities)
        case .station(let id): StationScreen(id: id)
        case .channel(let id): ChannelScreen(id: id)
        default: library
        }
    }

    @ViewBuilder private var library: some View {
        switch route {
        case .album(let id): AlbumScreen(id: id)
        case .artist(let id): ArtistScreen(id: id)
        case .nowPlaying: NowPlayingScreen()
        case .playlist(let id): PlaylistScreen(id: id)
        case .collection(let id): CollectionScreen(id: id)
        case .occasion(let occasion): OccasionScreen(occasion: occasion)
        default: EmptyView()
        }
    }
}
