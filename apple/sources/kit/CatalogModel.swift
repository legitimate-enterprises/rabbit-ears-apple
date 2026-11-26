import Foundation
import Observation
import RabbitEarsAPI

public typealias Person = Components.Schemas.Person
public typealias Credits = Components.Schemas.ItemCredits
public typealias Playability = Components.Schemas.Playability

extension Credits {
    /// Each crew job once, in credit order, with everyone who held it.
    public var crewLines: [(String, String)] {
        var order: [String] = []
        var names: [String: [String]] = [:]
        for credit in crew {
            let job = credit.job ?? "Crew"
            if names[job] == nil { order.append(job) }
            names[job, default: []].append(credit.name)
        }
        return order.map { ($0, names[$0, default: []].joined(separator: ", ")) }
    }
}

public typealias SearchResult = Components.Schemas.SearchResult

/// Search's sections in the order shown, the most specific kind first; each
/// shows only when it found something.
public enum SearchSection: String, CaseIterable, Sendable {
    case movies = "Movies"
    case tv = "TV"
    case songs = "Songs"
    case albums = "Albums"
    case artists = "Artists"
    case videos = "Videos"
    case channels = "Channels"
    case people = "People"
}

extension SearchResult {
    public static let empty = SearchResult(
        movies: [], shows: [], episodes: [], people: [], artists: [], albums: [], songs: [], channels: [], videos: [])

    public var tv: [Item] { episodes + shows }

    public var sections: [SearchSection] {
        SearchSection.allCases.filter { section in
            switch section {
            case .movies: !movies.isEmpty
            case .tv: !tv.isEmpty
            case .people: !people.isEmpty
            case .artists: !artists.isEmpty
            case .albums: !albums.isEmpty
            case .songs: !songs.isEmpty
            case .channels: !channels.isEmpty
            case .videos: !videos.isEmpty
            }
        }
    }
}

/// Loads the active profile's catalog and writes its watch state.
@MainActor
@Observable
public final class CatalogModel {
    public private(set) var catalog = Catalog()
    public private(set) var loaded = false
    /// Counts each finished `load`, so a view can follow the catalog reloading.
    public private(set) var revision = 0
    public private(set) var error: String?
    public let profileId: Int64
    public let client: Client
    /// Whether the profile leaves kids' content out of its browsing; the server then lists none of it.
    public private(set) var hidingKids: Bool
    /// What the Kids pill read under Hide, by kind, so a reload reads it again.
    @ObservationIgnored private var kidsTitles: [ItemKind: [Item]] = [:]
    /// Counts loads, so only the latest one's answer lands.
    @ObservationIgnored private var loads = 0

    public init(client: Client, profileId: Int64, hidingKids: Bool = false) {
        self.client = client
        self.profileId = profileId
        self.hidingKids = hidingKids
    }

    /// Fetches every movie, show, season and episode the profile may see.
    /// shortcut: the whole catalog is held in memory; move to server-side
    /// home, badge and search endpoints once libraries reach tens of
    /// thousands of episodes.
    public func load() async {
        loads += 1
        let mine = loads
        do {
            var next = try await fetch()
            var held: [ItemKind: [Item]] = [:]
            for kind in Array(kidsTitles.keys) { held[kind] = try await kids(kind) }
            guard mine == loads else { return }
            kidsTitles.merge(held) { $1 }
            for held in kidsTitles.values { next.hold(held) }
            catalog = next
            error = nil
        } catch {
            guard mine == loads else { return }
            self.error = AppError.from(error, unauthorized: .signedOut).localizedDescription
        }
        loaded = true
        revision += 1
    }

    /// The Kids pill is up on this kind. Under Hide the server leaves kids' content out of the
    /// catalog, so it is read apart, once, and kept out of everything but that pill; without
    /// Hide the pill filters what is held and nothing is asked.
    public func showKids(_ kind: ItemKind) async {
        guard hidingKids, kidsTitles[kind] == nil else { return }
        do {
            let held = try await kids(kind)
            // Hide changed, or a reload got there first, while the titles were on their way.
            guard hidingKids, kidsTitles[kind] == nil else { return }
            kidsTitles[kind] = held
            catalog.hold(held)
            error = nil
        } catch {
            guard !Task.isCancelled else { return }
            self.error = AppError.from(error, unauthorized: .signedOut).localizedDescription
        }
    }

    /// Takes the profile's Hide setting as the server now has it, as after a change on another
    /// device: a different one reads the catalog again without what was held apart.
    public func profileChanged(_ profile: Account?) async {
        guard let profile, profile.id == profileId, (profile.hideKidsContent == true) != hidingKids else { return }
        hidingKids.toggle()
        kidsTitles = [:]
        await load()
    }

    private nonisolated func fetch() async throws -> Catalog {
        async let movies = items(.movie)
        async let shows = items(.show)
        async let seasons = items(.season)
        async let episodes = items(.episode)
        async let watch = watchStates()
        return Catalog(items: try await movies + shows + seasons + episodes, watch: try await watch)
    }

    private nonisolated func items(_ kind: ItemKind, kidsOnly: Bool? = nil) async throws -> [Item] {
        try await allPages { offset in
            let page = try await self.client.listItems(
                query: .init(kind: kind, kidsContent: kidsOnly, limit: 200, offset: offset)
            ).ok.body.json
            return (page.items, page.nextOffset)
        }
    }

    /// Every kids' title of the kind, whatever Hide says, and a show's seasons and episodes.
    private nonisolated func kids(_ kind: ItemKind) async throws -> [Item] {
        let kinds: [ItemKind] = kind == .show ? [.show, .season, .episode] : [kind]
        return try await withThrowingTaskGroup(of: [Item].self) { group in
            for kind in kinds { group.addTask { try await self.items(kind, kidsOnly: true) } }
            return try await group.reduce(into: []) { $0 += $1 }
        }
    }

    private nonisolated func watchStates() async throws -> [WatchState] {
        try await allPages { offset in
            let page = try await self.client.listWatchStates(
                path: .init(profileId: self.profileId), query: .init(limit: 200, offset: offset)
            ).ok.body.json
            return (page.items, page.nextOffset)
        }
    }

    /// Marks an item watched or unwatched; a show or season marks each episode.
    public func setWatched(_ watched: Bool, for item: Item) async {
        let targets = item.kind == .show || item.kind == .season ? catalog.episodes(under: item.id) : [item]
        for target in targets {
            do {
                let state = try await client.putWatchState(
                    path: .init(profileId: profileId, itemId: target.id), body: .json(.init(watched: watched))
                ).ok.body.json
                catalog.record(state)
            } catch {
                self.error = AppError.from(error, unauthorized: .signedOut).localizedDescription
                return
            }
        }
    }

    /// Marks a selection in one request; a show or season marks each episode.
    public func setWatched(_ watched: Bool, for items: [Item]) async {
        do {
            _ = try await client.putWatchStates(
                path: .init(profileId: profileId), body: .json(.init(itemIds: items.map(\.id), watched: watched))
            ).noContent
            let now = Date()
            for item in items {
                for target in item.kind == .movie || item.kind == .episode ? [item] : catalog.episodes(under: item.id) {
                    catalog.record(
                        .init(
                            itemId: target.id, positionMs: 0, watched: watched,
                            playCount: catalog.watch[target.id]?.playCount ?? 0, lastPlayedAt: now, updatedAt: now))
                }
            }
            error = nil
        } catch {
            self.error = AppError.from(error, unauthorized: .signedOut).localizedDescription
        }
    }

    /// Sets kids' content on a selection of movies and shows in one request.
    public func setKidsContent(_ kidsContent: Bool, for items: [Item]) async {
        do {
            _ = try await client.setKidsContents(
                body: .json(.init(itemIds: items.map(\.id), kidsContent: kidsContent))
            ).noContent
            for var item in items {
                item.kidsContent = kidsContent
                item.kidsContentOverride = kidsContent
                catalog.replace(item)
            }
            error = nil
        } catch {
            self.error = AppError.from(error, unauthorized: .signedOut).localizedDescription
        }
    }

    /// Takes the server's watch state after play, since the server decides
    /// when a position counts as watched.
    public func refreshWatchState(_ id: Item.ID) async {
        do {
            catalog.record(try await client.getWatchState(path: .init(profileId: profileId, itemId: id)).ok.body.json)
        } catch {
            // The server holds none, as after Mark as unwatched on another device.
            if APIError.from(error)?.status == 404 { catalog.forget(id) }
        }
    }

    /// Takes what a batch of live events changed: the watch state of each
    /// title named, or everything for an empty batch or a library that changed.
    public func heard(_ batch: [LiveEvent]) async {
        if batch.isEmpty || batch.contains(where: { $0.kind == .library }) { return await load() }
        let ids = Set(batch.filter { $0.kind == .watchState || $0.kind == .playback }.compactMap(\.itemId))
        for id in ids where catalog.item(id) != nil { await refreshWatchState(id) }
    }

    /// How play would go on this device now, from the same snapshot the player
    /// sends; nil when it cannot tell.
    public func playability(_ id: Item.ID, facts: DeviceFacts, server: ServerEndpoint) async -> Playability? {
        let snapshot = await server.snapshot(facts, checkedWith: client, maxBitrate: nil)
        return try? await client.checkPlayability(path: .init(itemId: id), body: .json(snapshot)).ok.body.json
    }

    public func credits(_ id: Item.ID) async -> Credits? {
        try? await client.getItemCredits(path: .init(itemId: id)).ok.body.json
    }

    /// Everything matching the query across every library, as the server
    /// filters it for the profile; nil when the server could not answer.
    public func search(_ query: String, limit: Int = 20) async -> SearchResult? {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return .empty }
        return try? await client.search(query: .init(q: String(query.prefix(200)), limit: limit)).ok.body.json
    }

    /// Overrides whether a movie or show is kids' content; nil leaves it to the rating again.
    public func setKidsContent(_ kidsContent: Bool?, for item: Item) async {
        let id = item.id
        do {
            if let kidsContent {
                let body = Components.Schemas.KidsContentInput(kidsContent: kidsContent)
                catalog.replace(
                    try await client.setKidsContent(path: .init(itemId: id), body: .json(body)).ok.body.json)
            } else {
                _ = try await client.clearKidsContent(path: .init(itemId: id)).noContent
                catalog.replace(try await client.getItem(path: .init(itemId: id)).ok.body.json)
            }
            error = nil
        } catch {
            self.error = AppError.from(error, unauthorized: .signedOut).localizedDescription
        }
    }

    /// The person and the movies and shows crediting them.
    public func person(_ id: Person.ID) async -> (Person, [Item])? {
        do {
            async let person = client.getPerson(path: .init(personId: id)).ok.body.json
            let items = try await allPages { offset in
                let page = try await self.client.listItems(query: .init(personId: id, limit: 200, offset: offset))
                    .ok.body.json
                return (page.items, page.nextOffset)
            }
            return (try await person, items)
        } catch {
            return nil
        }
    }
}
