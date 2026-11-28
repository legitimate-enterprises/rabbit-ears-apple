import Foundation
import GRDB
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
    public let profileId: UID
    public let client: Client
    public let replica: Replica
    public let queue: ActionQueue
    /// Whether the profile leaves kids' content out of its browsing.
    public private(set) var hidingKids: Bool
    /// Counts loads, so only the latest one's answer lands.
    @ObservationIgnored private var loads = 0

    public init(client: Client, replica: Replica, queue: ActionQueue, profileId: UID, hidingKids: Bool = false) {
        self.client = client
        self.replica = replica
        self.queue = queue
        self.profileId = profileId
        self.hidingKids = hidingKids
    }

    /// Reads every movie, show, season and episode the profile browses, as
    /// the replica's views decide, and under Hide kids' content the kids'
    /// titles apart, for the Kids pill alone. Before the replica's first
    /// snapshot nothing is loaded.
    /// shortcut: the whole catalog is held in memory; read each view's rows
    /// from the replica once libraries reach tens of thousands of episodes.
    public func load() async {
        loads += 1
        let mine = loads
        do {
            let next = try await replica.read { [profileId] in try Self.catalog(profileId, $0) }
            guard mine == loads else { return }
            catalog = next
            error = nil
        } catch Replica.Failure.empty {
            return
        } catch {
            guard mine == loads else { return }
            self.error = AppError.from(error).localizedDescription
        }
        loaded = true
        revision += 1
    }

    private nonisolated static func catalog(_ profile: UID, _ db: Database) throws -> Catalog {
        let browsed = "i.id IN (SELECT item_id FROM profile_item WHERE account_id = ?)"
        var catalog = Catalog(
            items: try ReplicaRows.items(db, browsed, [profile], for: profile), watch: try watch(profile, db))
        catalog.hold(
            try ReplicaRows.items(
                db,
                "i.id IN (SELECT item_id FROM kids_item) AND NOT \(browsed)"
                    + " AND i.id IN (SELECT item_id FROM profile_item_open WHERE account_id = ?)",
                [profile, profile], for: profile))
        return catalog
    }

    /// The profile's watch states of what it browses, as listWatchStates answers.
    private nonisolated static func watch(_ profile: UID, _ db: Database) throws -> [WatchState] {
        try Row.fetchAll(
            db,
            sql: """
                SELECT * FROM watch_state
                WHERE account_id = ? AND item_id IN (SELECT item_id FROM profile_item WHERE account_id = ?)
                """, arguments: [profile, profile]
        ).map(ReplicaRows.watchState)
    }

    /// Takes the profile's Hide setting as the server now has it, as after a change on another
    /// device: a different one reads the catalog again.
    public func profileChanged(_ profile: Account?) async {
        guard let profile, profile.id == profileId, (profile.hideKidsContent == true) != hidingKids else { return }
        hidingKids.toggle()
        await load()
    }

    /// Marks an item watched or unwatched; a show or season marks each episode.
    public func setWatched(_ watched: Bool, for item: Item) async {
        let targets = item.kind == .show || item.kind == .season ? catalog.episodes(under: item.id) : [item]
        do {
            for target in targets { try await queue.putWatchState(watched, item: target.id, as: profileId) }
        } catch {
            self.error = AppError.from(error, unauthorized: .signedOut).localizedDescription
        }
        await heard(.watched)
    }

    /// Marks a selection; a show or season marks each episode.
    public func setWatched(_ watched: Bool, for items: [Item]) async {
        do {
            try await queue.putWatchStates(watched, items: items.map(\.id), as: profileId, in: replica)
            error = nil
        } catch {
            self.error = AppError.from(error, unauthorized: .signedOut).localizedDescription
        }
        await heard(.watched)
    }

    /// Sets kids' content on a selection of movies and shows.
    public func setKidsContent(_ kidsContent: Bool, for items: [Item]) async {
        do {
            try await queue.setKidsContents(kidsContent, for: items.map(\.id), as: profileId)
            error = nil
        } catch {
            self.error = AppError.from(error, unauthorized: .signedOut).localizedDescription
        }
        await heard(.library)
    }

    /// Takes the replica's watch state of a title after play, which holds
    /// the server's once caught up, since the server decides when a position
    /// counts as watched.
    public func refreshWatchState(_ id: Item.ID) async {
        let profile = profileId
        let state: WatchState?
        do {
            state = try await replica.read { db in
                try Row.fetchOne(
                    db,
                    sql: """
                        SELECT * FROM watch_state WHERE account_id = ? AND item_id = ?
                            AND item_id IN (SELECT item_id FROM profile_item_open WHERE account_id = ?)
                        """, arguments: [profile, id, profile]
                ).map(ReplicaRows.watchState)
            }
        } catch {
            return
        }
        // None, as after Mark as unwatched on another device.
        if let state { catalog.record(state) } else { catalog.forget(id) }
    }

    /// Takes what a commit to the replica changed: the watch states, or
    /// everything when the library or the profiles changed.
    public func heard(_ group: Replica.Group) async {
        switch group {
        case .library, .household: await load()
        case .watched:
            let profile = profileId
            guard let fresh = try? await replica.read({ try Self.watch(profile, $0) }) else { return }
            var next = catalog
            let kept = Set(fresh.map(\.itemId))
            for id in next.watch.keys where !kept.contains(id) { next.forget(id) }
            for state in fresh { next.record(state) }
            catalog = next
        case .playlists, .stations: break
        }
    }

    /// How play would go on this device now, from the same snapshot the player
    /// sends; nil when it cannot tell.
    public func playability(_ id: Item.ID, facts: DeviceFacts, server: ServerEndpoint) async -> Playability? {
        let snapshot = await server.snapshot(facts, checkedWith: client, maxBitrate: nil)
        return try? await client.checkPlayability(path: .init(itemId: id), body: .json(snapshot)).ok.body.json
    }

    /// The credits of an item the profile may see, as getItemCredits answers them.
    public func credits(_ id: Item.ID) async -> Credits? {
        (try? await replica.read { [profileId] db -> Credits? in
            guard
                try Bool.fetchOne(
                    db, sql: "SELECT 1 FROM item WHERE id = ? AND id " + ReplicaRows.seenBy, arguments: [id, profileId])
                    == true
            else { return nil }
            var credits = Credits(cast: [], crew: [])
            for row in try Row.fetchAll(
                db,
                sql: """
                    SELECT c.person_id, p.name, p.profile_path, p.headshot_url, c.kind, c.character, c.job, c.department
                    FROM credit_shown c JOIN person p ON p.id = c.person_id
                    WHERE c.item_id = ? ORDER BY c.kind, c.position
                    """, arguments: [id])
            {
                let text = { (column: String) in (row[column] as String?).flatMap { $0.isEmpty ? nil : $0 } }
                let credit = Components.Schemas.Credit(
                    personId: row["person_id"], name: row["name"], profilePath: text("profile_path"),
                    headshotUrl: text("headshot_url"),
                    character: text("character"), job: text("job"), department: text("department"))
                if row["kind"] == "cast" { credits.cast.append(credit) } else { credits.crew.append(credit) }
            }
            return credits
        }) ?? nil
    }

    /// Everything matching the query across every library, as the server
    /// filters it for the profile; nil when the replica could not be read.
    public func search(_ query: String, limit: Int = 20) async -> SearchResult? {
        let query = String(query.trimmingCharacters(in: .whitespaces).prefix(200))
        guard !query.isEmpty else { return .empty }
        let profile = profileId
        return try? await replica.read { try Self.search(query, limit, profile, $0) }
    }

    /// Movies, shows, episodes and people as the server's search finds
    /// them for the profile's browsing, each list best first.
    private nonisolated static func search(
        _ query: String, _ limit: Int, _ profile: UID, _ db: Database
    ) throws -> SearchResult {
        let itemOrder = try ReplicaSearch.items(matching: query, in: db)
        let items = Dictionary(
            uniqueKeysWithValues: try ReplicaRows.items(
                db,
                "i.id IN (SELECT unhex(value, '-') FROM json_each(?))"
                    + " AND i.id IN (SELECT item_id FROM profile_item WHERE account_id = ?)",
                [ReplicaRows.json(itemOrder), profile], for: profile
            ).map { ($0.id, $0) })
        let personOrder = try ReplicaSearch.people(matching: query, in: db)
        let people = Dictionary(
            uniqueKeysWithValues: try Row.fetchAll(
                db, sql: Self.peopleSQL + " AND p.id IN (SELECT unhex(value, '-') FROM json_each(?))",
                arguments: [profile, ReplicaRows.json(personOrder)]
            ).map(ReplicaRows.person).map { ($0.id, $0) })
        let found = itemOrder.compactMap { items[$0] }
        let kind = { (kind: ItemKind) in Array(found.filter { $0.kind == kind }.prefix(limit)) }
        var result = SearchResult.empty
        (result.movies, result.shows, result.episodes) = (kind(.movie), kind(.show), kind(.episode))
        result.people = Array(personOrder.compactMap { people[$0] }.prefix(limit))
        let music = MusicRows.Filter(query: query, limit: limit)
        result.artists = try MusicRows.artists(db, profile, music).0
        result.albums = try MusicRows.albums(db, profile, music).0
        result.songs = try MusicRows.songs(db, profile, music).0
        result.channels = Array(try YouTubeRows.channels(db, profile, sort: "best", query: query).prefix(limit))
        result.videos = try YouTubeRows.videos(db, profile, .init(query: query, sort: "best", limit: limit)).0
        return result
    }

    /// Overrides whether a movie or show is kids' content; nil leaves it to the rating again.
    public func setKidsContent(_ kidsContent: Bool?, for item: Item) async {
        do {
            try await queue.setKidsContent(kidsContent, for: item.id, as: profileId)
            error = nil
        } catch {
            self.error = AppError.from(error, unauthorized: .signedOut).localizedDescription
        }
        await heard(.library)
    }

    /// People the profile browses, over `person p`; it binds the profile.
    /// As the server's person.seen: an adult meets whom TMDB names, anyone
    /// those credited on what they browse.
    private nonisolated static let peopleSQL = """
        SELECT p.id, p.name, p.tmdb_id, p.profile_path, p.headshot_url FROM person p
            CROSS JOIN metadata_setting z JOIN profile_audience a ON a.account_id = ?
        WHERE (a.browse_mode = 0 AND (p.tmdb_id IS NULL OR z.use_remote)
            OR EXISTS (SELECT 1 FROM credit_shown c JOIN profile_item v ON v.item_id = c.item_id
                AND v.account_id = a.account_id WHERE c.person_id = p.id))
        """

    /// The person and the titles crediting them that the profile browses, by title.
    public func person(_ id: Person.ID) async -> (Person, [Item])? {
        (try? await replica.read { [profileId] db -> (Person, [Item])? in
            guard let person = try Row.fetchOne(db, sql: Self.peopleSQL + " AND p.id = ?", arguments: [profileId, id])
            else { return nil }
            let items = try ReplicaRows.items(
                db,
                "EXISTS (SELECT 1 FROM credit_shown c WHERE c.item_id = i.id AND c.person_id = ?)"
                    + " AND i.id \(ReplicaRows.browsedBy) ORDER BY \(ReplicaRows.titleOrder)", [id, profileId],
                for: profileId)
            return (ReplicaRows.person(person), items)
        }) ?? nil
    }
}
