import RabbitEarsAPI
import RabbitEarsKit
import SwiftUI

enum LibraryTab: String, CaseIterable, Identifiable {
    case home = "Home"
    case tv = "TV"
    case movies = "Movies"
    case music = "Music"
    case youtube = "YouTube"

    var id: Self { self }

    /// The library section it shows; Home shows none.
    var section: LibrarySection? {
        switch self {
        case .home: nil
        case .tv: .tv
        case .movies: .movies
        case .music: .music
        case .youtube: .youtube
        }
    }

    init(_ section: LibrarySection?) {
        self = Self.allCases.first { $0.section == section } ?? .home
    }

    var icon: String {
        switch self {
        case .home: "house"
        case .tv: "tv"
        case .movies: "film"
        case .music: "music.note"
        case .youtube: "play.rectangle"
        }
    }
}

/// A page in a tab's stack.
enum Route: Hashable {
    case item(Item.ID)
    case person(Person.ID)
    case search
    case youtubeSearch
    case album(Int64)
    case artist(Int64)
    case playlist(Int64)
    case collection(Int64)
    case occasion(ActiveOccasion)
    case channel(Int64)
    case video(Int64)
    case station(Int64)
}

/// Navigation shared by every browsing view: each tab's stack and what is playing.
@MainActor
@Observable
final class Browser: VideoBrowser {
    var section = LibraryTab.home
    var paths: [LibraryTab: [Route]] = [:]
    var playing: PlayRequest?
    var showingNowPlaying = false
    /// The movies or tv station playing in its own player, in place of `playing`.
    var tuning: Station?
    var editingStation: StationEditRequest?
    /// A refusal to show in an alert, as deleting a playlist a station plays.
    var alert: String?
    /// Rises after a station edit, so the views showing stations read them again.
    var revision = 0

    func path(_ section: LibraryTab) -> Binding<[Route]> {
        Binding(get: { self.paths[section, default: []] }, set: { self.paths[section] = $0 })
    }

    func open(_ item: Item) { paths[section, default: []].append(.item(item.id)) }
    func replace(with item: Item) { paths[section, default: []].replaceTop(with: .item(item.id)) }
    func open(person id: Person.ID) { paths[section, default: []].append(.person(id)) }
    func open(_ route: Route) { paths[section, default: []].append(route) }

    /// Every library is searched at once, but YouTube's own search filters its videos.
    func search() { open(section == .youtube ? .youtubeSearch : .search) }

    /// Plays a row of a playlist's play order; a later row replaces the
    /// player inside the open cover, as Next episode does.
    func play(_ queue: VideoQueue) {
        let next = playing != nil
        playing = PlayRequest(
            id: playing?.id ?? UUID(), item: queue.current, editionId: queue.editionId, positionMs: next ? 0 : nil,
            queue: queue)
    }
}

/// Follows the server's live events while the app is in view, loads again
/// what each says has changed, and shows the app's brief notices.
struct LiveUpdates: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    let catalog: CatalogModel?
    let services: Services?
    let browser: Browser

    func body(content: Content) -> some View {
        content
            .task(id: "\(catalog.map { ObjectIdentifier($0).hashValue } ?? 0)/\(scenePhase == .background)") {
                await model.followLive(catalog, inView: scenePhase != .background)
            }
            // Back in view, the downloads catch up: watch changes made offline go up, then what is new comes down.
            .task(id: "\(model.activeProfile?.id ?? 0)/\(scenePhase == .active)") {
                guard scenePhase == .active, let profile = model.activeProfile?.id else { return }
                await model.downloads?.sync(profile: profile)
            }
            .onChange(of: model.live.watched) { browser.revision += 1 }
            .onChange(of: model.live.stations) { browser.revision += 1 }
            .onChange(of: model.live.playlists) {
                browser.revision += 1
                Task { await services?.playlists.load() }
            }
            .overlay(alignment: .bottom) {
                if let notice = model.live.notice {
                    Text(notice).font(.system(size: 15, weight: .semibold)).padding(.horizontal, 16)
                        .frame(height: 38).background(.black.opacity(0.8), in: .capsule).padding(.bottom, 96)
                }
            }
    }
}

struct MainView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var prompt = DownloadPrompt()
    @State private var catalog: CatalogModel?
    @State private var services: Services?
    @State private var browser = Browser()

    var body: some View {
        Group {
            if let catalog, let services {
                tabs(catalog, services)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // Hide kids' content changes what the server lists, so the catalog is read again.
        .task(id: "\(model.activeProfile?.id ?? 0)/\(model.activeProfile?.hideKidsContent == true)") {
            // CarPlay may have made this profile's services already; the context shares them.
            guard let client = model.client, let profile = model.activeProfile,
                let nextServices = await AppContext.shared.services(for: profile.id)
            else { return }
            let next = CatalogModel(client: client, profileId: profile.id, hidingKids: profile.hideKidsContent == true)
            catalog = next
            services = nextServices
            async let load: Void = next.load()
            async let collections: Void = nextServices.collections.load()
            await nextServices.playlists.load()
            await load
            await collections
        }
        // The libraries a server has decide the tabs: asked on sign-in, a profile's change and return to the app.
        // The profile is read again then too, for a Hide kids' content changed on another device.
        .task(id: "\(model.activeProfile?.id ?? 0)/\(scenePhase == .active)") {
            guard scenePhase == .active else { return }
            await model.reload()
            await model.loadLibrarySections()
        }
        // A title's menu shows which kids' lists hold it without asking per tile.
        .task(id: "\(model.activeProfile?.id ?? 0)/\(model.allowListKids.map(\.id))/\(scenePhase == .active)") {
            if scenePhase == .active { await model.loadAllowLists() }
        }
        .onChange(of: model.librarySections) {
            browser.section = LibraryTab(LibrarySection.selection(browser.section.section, in: model.librarySections))
        }
        .modifier(LiveUpdates(catalog: catalog, services: services, browser: browser))
        .downloadPrompt(prompt, store: model.downloads)
        .onDisappear { Task { await services?.stop() } }
    }

    private func tabs(_ catalog: CatalogModel, _ services: Services) -> some View {
        TabView(selection: $browser.section) {
            ForEach(LibraryTab.allCases.filter { $0.section.map(model.librarySections.contains) ?? true }) { section in
                Tab(section.rawValue, systemImage: section.icon, value: section) {
                    NavigationStack(path: browser.path(section)) {
                        root(section, catalog)
                            .navigationDestination(for: Route.self) { destination($0).environment(catalog) }
                    }
                }
            }
        }
        .tabViewBottomAccessory(isEnabled: services.player.current != nil || services.player.station != nil) {
            MiniPlayer(player: services.player) { browser.showingNowPlaying = true }
        }
        .titleMenuHost()
        .environment(browser)
        .environment(services)
        .fullScreenCover(isPresented: $browser.showingNowPlaying) {
            NowPlayingView(player: services.player).environment(browser).environment(services)
        }
        .fullScreenCover(item: $browser.playing) { request in
            if let client = model.client, let endpoint = model.endpoint, let profile = model.activeProfile {
                HandoffGate(request: request, client: client, profileId: profile.id, browser: browser) {
                    browser.playing = nil
                } player: {
                    PlayerScreen(
                        request: request, client: client, endpoint: endpoint, profileId: profile.id,
                        close: { browser.playing = nil }
                    )
                    .environment(catalog)
                }
                .environment(browser)
                .environment(model)
                // Rebuilt too for the answer to the handoff prompt, which plays the same title another way.
                .id(HandoffGate<PlayerScreen>.identity(request))
            }
        }
        .fullScreenCover(item: $browser.tuning) { station in
            if let client = model.client, let endpoint = model.endpoint, let profile = model.activeProfile {
                StationPlayerScreen(
                    station: station, client: client, endpoint: endpoint, profileId: profile.id,
                    close: { browser.tuning = nil })
            }
        }
        .sheet(item: $browser.editingStation) { request in
            StationEditor(request: request).environment(browser).environment(services)
        }
        .alert(
            browser.alert ?? "",
            isPresented: Binding(get: { browser.alert != nil }, set: { if !$0 { browser.alert = nil } })
        ) {
            Button("OK") {}
        }
        .onChange(of: browser.playing == nil && browser.tuning == nil) { _, free in
            // Video and music share one speaker and the system's transport; a video or station takes both.
            guard !free else { return services.player.attach(AppContext.shared.center) }
            services.player.detach()
            Task { await services.player.pause() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .playNext)) { note in
            if let id = note.object as? Item.ID, let next = catalog.catalog.item(id) { browser.playNext(next) }
        }
    }

    private func root(_ section: LibraryTab, _ catalog: CatalogModel) -> some View {
        Group {
            if catalog.loaded {
                Group {
                    if let error = catalog.error, catalog.catalog.items.isEmpty {
                        ContentUnavailableView {
                            Label("Can't load the library", systemImage: "wifi.exclamationmark")
                        } description: {
                            Text(error)
                        } actions: {
                            Button("Try again") { Task { await catalog.load() } }.buttonStyle(SecondaryButtonStyle())
                        }
                        .navigationTitle(section.rawValue)
                        .toolbar { BrowseToolbar() }
                    } else {
                        switch section {
                        case .home: HomeView().navigationTitle(section.rawValue).toolbar { BrowseToolbar() }
                        case .tv: GridView(kind: .show)
                        case .movies: GridView(kind: .movie)
                        case .music: MusicView()
                        case .youtube: YouTubeView()
                        }
                    }
                }
                .environment(catalog)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                    .navigationTitle(section.rawValue)
                    .toolbar { BrowseToolbar() }
            }
        }
        .background(Theme.ground)
    }

    @ViewBuilder
    private func destination(_ route: Route) -> some View {
        switch route {
        case .item(let id): DetailView(id: id)
        case .person(let id): PersonView(id: id)
        case .search: SearchView()
        case .youtubeSearch: YouTubeSearchView()
        case .album(let id): AlbumView(id: id)
        case .artist(let id): ArtistView(id: id)
        default: libraryDestination(route)
        }
    }

    @ViewBuilder
    private func libraryDestination(_ route: Route) -> some View {
        switch route {
        case .playlist(let id): PlaylistView(id: id)
        case .collection(let id): CollectionView(id: id)
        case .occasion(let occasion): OccasionView(occasion: occasion)
        case .channel(let id): ChannelView(id: id)
        case .video(let id): VideoView(id: id)
        case .station(let id): StationView(id: id)
        default: EmptyView()
        }
    }
}

/// Search and profile, last in a view's toolbar so they keep their places
/// whatever trailing items the view declares before it.
struct BrowseToolbar: ToolbarContent {
    var search = true

    var body: some ToolbarContent {
        // Keeps search out of the glass a preceding icon would otherwise share with it.
        ToolbarSpacer(.fixed, placement: .topBarTrailing)
        ToolbarItemGroup(placement: .topBarTrailing) {
            if search { SearchButton() }
            ProfileMenu()
        }
    }
}

extension View {
    /// A library page's large title with its count beside it, small and
    /// secondary; the collapsed bar shows the bare title.
    func countedTitle(_ title: String, count: String) -> some View {
        navigationTitle(title).toolbar {
            ToolbarItem(placement: .largeTitle) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(title).font(.largeTitle.bold())
                    if !count.isEmpty { Text("(\(count))").font(.system(size: 14)).foregroundStyle(Theme.secondary) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                // As tall as the system's large title area, so the page below starts where it would.
                .padding(.top, 11)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
            }
        }
    }
}

struct ProfileMenu: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @State private var changingPassword = false
    @State private var managing = false
    @State private var preferring = false
    @State private var deleting = false
    @Environment(\.displayScale) private var scale
    @State private var picture: UIImage?

    var body: some View {
        let profile = model.activeProfile
        Menu {
            Button("Switch profile", systemImage: "person.2") { Task { await model.switchProfile() } }
            if profile?.kind == .adult {
                Button("Preferences", systemImage: "paintpalette") { preferring = true }
                Button("Manage household", systemImage: "house") { managing = true }
                if profile?.isAdmin == true, let admin = model.endpoint?.resolve("/admin/") {
                    Button("Admin", systemImage: "gearshape") { openURL(admin) }
                }
                Button("Password", systemImage: "key") { changingPassword = true }
                Button("Delete account", systemImage: "person.crop.circle.badge.xmark", role: .destructive) {
                    deleting = true
                }
            }
            Button("Sign out", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                Task { await model.signOut() }
            }
        } label: {
            // A title keeps the item named if the bar folds it into overflow.
            Label {
                Text(profile?.name ?? "")
            } icon: {
                // The bar draws only an image here, and as it comes; without a picture it shows the name.
                if let picture { Image(uiImage: picture) }
            }
            .labelStyle(.titleAndIcon)
        }
        .task(id: "\(profile?.id ?? 0)/\(profile?.avatarUrl ?? "")") {
            guard let profile else {
                picture = nil
                return
            }
            let bitmap = await model.artwork?.avatarImage(profile, maxPixel: ArtImage.pixels(32, scale))
            picture = bitmap.map { UIImage.barPicture($0, size: 32) }
        }
        .accessibilityLabel("Profile: \(profile?.name ?? "")")
        .sheet(isPresented: $changingPassword) { ChangePasswordView() }
        .sheet(isPresented: $managing) { ManageHouseholdView() }
        .sheet(isPresented: $preferring) { PreferencesView() }
        .sheet(isPresented: $deleting) { DeleteAccountView() }
    }
}
