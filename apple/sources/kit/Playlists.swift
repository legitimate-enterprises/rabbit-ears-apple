import Foundation
import GRDB
import Observation
import RabbitEarsAPI

public typealias Playlist = Components.Schemas.Playlist
public typealias PlaylistEntry = Components.Schemas.PlaylistEntry
public typealias PlaylistKind = Components.Schemas.PlaylistKind
public typealias PlayOrderRow = Components.Schemas.PlaylistPlayOrderItem

/// The active profile's playlists and those shared with it. Each holds one
/// library kind, movies, tv or music; kids own none and only read, and the
/// server answers writes beyond a playlist's access with 403.
@MainActor
@Observable
public final class PlaylistsModel {
    public private(set) var playlists: [Playlist] = []
    public private(set) var error: String?
    /// Set when an add needs the adult to pick an edition; clear it to drop the add.
    public var editionQuestion: EditionQuestion?
    public let client: Client
    public let replica: Replica
    public let queue: ActionQueue
    public let engine: SyncEngine
    public let profileId: Int64
    /// An adult makes and adds to playlists; a kid only has those shared with them.
    public let adult: Bool

    public init(
        client: Client, replica: Replica, queue: ActionQueue, engine: SyncEngine, profileId: Int64, adult: Bool = true
    ) {
        self.client = client
        self.replica = replica
        self.queue = queue
        self.engine = engine
        self.profileId = profileId
        self.adult = adult
    }

    public func shares(of playlist: Int64) -> PlaylistSharesModel {
        PlaylistSharesModel(client: client, queue: queue, profileId: profileId, playlistId: playlist)
    }

    /// Whether the profile gets a Playlists view of kind: an adult always, a
    /// kid once one of kind is shared with them.
    public func offersView(_ kind: PlaylistKind) -> Bool { adult || !playlists(kind).isEmpty }

    /// The playlists of kind an adult may add to: their own and those shared for write.
    public func editable(_ kind: PlaylistKind) -> [Playlist] {
        adult ? playlists(kind).filter(\.isEditable) : []
    }

    /// Before the replica's first snapshot nothing is loaded.
    public func load() async {
        await write {
            do {
                playlists = try await replica.read { [profileId] in try PlaylistRows.playlists($0, profile: profileId) }
            } catch Replica.Failure.empty {}
        }
    }

    public func playlists(_ kind: PlaylistKind) -> [Playlist] { playlists.filter { $0.kind == kind } }

    // shortcut: online-only until offline ids are decided
    @discardableResult
    public func create(name: String, kind: PlaylistKind) async -> Playlist? {
        guard let name = Self.name(name) else { return nil }
        var created: Playlist?
        await write {
            let playlist = try await client.createPlaylist(
                path: .init(profileId: profileId), body: .json(.init(name: name, kind: kind))
            ).created.body.json
            try await caughtUp()
            created = playlist
        }
        return created
    }

    public func rename(_ playlist: Playlist, to name: String) async {
        guard let name = Self.name(name) else { return }
        await write {
            try await queue.renamePlaylist(as: profileId, playlist.id, name: name, kind: playlist.kind)
            try await reload()
        }
    }

    /// False when it was refused, as while one of the owner's stations plays the playlist.
    @discardableResult
    public func delete(_ playlist: Playlist) async -> Bool {
        await write {
            try await queue.deletePlaylist(as: profileId, playlist.id)
            try await reload()
        }
    }

    /// The entries top to bottom; nil when they could not be read.
    public func entries(of playlistId: Int64) async -> [PlaylistEntry]? {
        var entries: [PlaylistEntry]?
        await write {
            entries = try await readPlaylist(playlistId) { db, profile in
                try PlaylistRows.entries(db, profile: profile, playlist: playlistId)
            }
        }
        return entries
    }

    /// What "Pick a title's artwork" offers from the playlist's entries; empty when none or unread.
    public func artChoices(of playlistId: Int64) async -> [ArtChoice] {
        let entries = try? await readPlaylist(playlistId) { db, profile in
            try PlaylistRows.entries(db, profile: profile, playlist: playlistId)
        }
        return CustomImage.choices(entries ?? [])
    }

    /// What playing the playlist plays; nil when it could not be read.
    /// Containers are expanded as the server expands them, so this is the
    /// only source of what plays.
    public func playOrder(of playlistId: Int64) async -> [PlayOrderRow]? {
        var rows: [PlayOrderRow]?
        await write {
            rows = try await readPlaylist(playlistId) { db, profile in
                try PlaylistRows.playOrder(db, profile: profile, playlist: playlistId)
            }
        }
        return rows
    }

    /// Adds an item at `position`, or last; false when the server refused,
    /// as for a song in a movies playlist. A title of several editions added
    /// without one is not refused: it sets `editionQuestion` and answers false.
    @discardableResult
    public func add(
        _ itemId: Int64, to playlistId: Int64, at position: Int? = nil, edition editionId: Int64? = nil
    ) async -> Bool {
        var question: EditionQuestion?
        let added = await write {
            do {
                try await insert(.init(itemId: itemId, position: position, editionId: editionId), into: playlistId)
            } catch  where editionId == nil && APIError.from(error)?.fields.contains("editionId") == true {
                let editions = try await replica.read { try Editions.of(itemId, $0) }
                guard !editions.isEmpty else { throw error }
                question = EditionQuestion(
                    itemId: itemId, playlistId: playlistId, position: position, editions: editions)
            }
        }
        editionQuestion = question
        return added && question == nil
    }

    /// Adds the title asked about again, with the edition picked.
    @discardableResult
    public func answer(_ question: EditionQuestion, with edition: Edition) async -> Bool {
        editionQuestion = nil
        return await add(question.itemId, to: question.playlistId, at: question.position, edition: edition.id)
    }

    /// Adds a collection as one entry; only a movies playlist takes one.
    @discardableResult
    public func add(collection collectionId: Int64, to playlistId: Int64) async -> Bool {
        await write { try await insert(.init(collectionId: collectionId), into: playlistId) }
    }

    // shortcut: online-only until offline ids are decided
    /// Appends a selection in one request, to a playlist or a station's own;
    /// a title of several editions takes its default one.
    @discardableResult
    public func add(_ itemIds: [Int64], to playlistId: Int64) async -> Bool {
        await write {
            _ = try await client.addPlaylistEntries(
                path: .init(profileId: profileId, playlistId: playlistId),
                body: .json(.init(entries: itemIds.map { .init(itemId: $0) }))
            ).noContent
            try await caughtUp()
        }
    }

    // shortcut: online-only until offline ids are decided
    private func insert(_ input: Components.Schemas.PlaylistEntryInput, into playlistId: Int64) async throws {
        _ = try await client.addPlaylistEntry(
            path: .init(profileId: profileId, playlistId: playlistId), body: .json(input)
        ).created.body.json
        try await caughtUp()
    }

    public func remove(_ entry: PlaylistEntry) async {
        await write {
            try await queue.removeEntry(as: profileId, entry)
            try await reload()
        }
    }

    /// Moves an entry to `position` counted from 0 at the top.
    public func move(_ entry: PlaylistEntry, to position: Int) async {
        await write {
            let rank = try await replica.read {
                try PlaylistRows.rank($0, playlist: entry.playlistId, except: entry.id, at: position)
            }
            try await queue.rankEntry(as: profileId, entry, rank: rank)
            try await reload()
        }
    }

    /// After a write the server made, its rows are pulled before the list is read again.
    private func caughtUp() async throws {
        try? await engine.catchUp()
        try await reload()
    }

    private func reload() async throws {
        playlists = try await replica.read { [profileId] in try PlaylistRows.playlists($0, profile: profileId) }
    }

    /// Reads what `body` reads of a playlist the profile owns or that reaches it; one it cannot see is not found.
    private func readPlaylist<T: Sendable>(
        _ id: Int64, _ body: @escaping @Sendable (Database, Int64) throws -> T
    ) async throws -> T {
        try await replica.read { [profileId] db in
            guard try PlaylistRows.playlist(db, profile: profileId, id: id) != nil else {
                throw AppError.server("not found")
            }
            return try body(db, profileId)
        }
    }

    private static func name(_ name: String) -> String? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : String(name.prefix(100))
    }

    @discardableResult
    private func write(_ body: () async throws -> Void) async -> Bool {
        do {
            try await body()
            error = nil
            return true
        } catch {
            self.error = AppError.from(error, unauthorized: .signedOut).localizedDescription
            return false
        }
    }
}

/// An add the server would not take without an edition, and the editions to pick from.
public struct EditionQuestion: Identifiable, Sendable {
    public let itemId: Int64
    public let playlistId: Int64
    public let position: Int?
    public let editions: [Edition]
    public var id: Int64 { itemId }
}

extension PlaylistKind {
    /// The kind of playlist a movie, show, season or episode goes in.
    public init(holding kind: ItemKind) {
        self = kind == .movie ? .movies : .tv
    }
}

extension PlaylistEntry {
    /// Its poster's item; a song shows its album's and a collection its own,
    /// which `kind` tells apart.
    public var artId: Int64 { song?.albumId ?? itemId ?? collectionId ?? id }
}

extension Array where Element == PlayOrderRow {
    public var songs: [MusicSong] { compactMap(\.song) }

    /// Where an entry's rows begin among the playable ones; nil when it
    /// stands for nothing now, as a show with no episodes.
    public func start(of entryId: Int64) -> Int? {
        guard let first = firstIndex(where: { $0.entryId == entryId }) else { return nil }
        return self[..<first].filter { $0.song != nil || $0.item != nil }.count
    }
}

/// A movies or tv playlist in the video player: its movies and episodes in
/// play order and the row on screen, each row playing its own edition.
/// Ending a row plays the next.
public struct VideoQueue: Hashable, Sendable {
    public let playlistId: Int64
    public let items: [Item]
    private let rows: [PlayOrderRow]
    public let index: Int

    public init?(_ rows: [PlayOrderRow], start: Int, playlistId: Int64) {
        let rows = rows.filter { $0.item != nil }
        guard rows.indices.contains(start) else { return nil }
        self.rows = rows
        self.items = rows.compactMap(\.item)
        self.index = start
        self.playlistId = playlistId
    }

    public var current: Item { items[index] }
    public var editionId: Int64? { rows[index].editionId }
    /// Present only while the title has more than one edition.
    public var editionName: String? { rows[index].editionName }
    public var next: VideoQueue? { VideoQueue(rows, start: index + 1, playlistId: playlistId) }
    public func at(_ row: Int) -> VideoQueue? { VideoQueue(rows, start: row, playlistId: playlistId) }
}

/// The lines under a playlist's name and an entry's title.
public enum PlaylistText {
    /// `3 movies · 6h 10m`, `12 episodes · 8h` or `48 songs · 3h 2m`.
    public static func summary(_ playlist: Playlist) -> String {
        "\(count(playlist)) · \(Format.runtime(minutes: minutes(playlist.durationMs)))"
    }

    /// `3 movies`, `12 episodes` or `48 songs`.
    public static func count(_ playlist: Playlist) -> String {
        let noun =
            switch playlist.kind {
            case .movies: "movie"
            case .tv: "episode"
            case .music: "song"
            }
        return Format.count(playlist.itemCount, noun)
    }

    public static func title(_ entry: PlaylistEntry) -> String {
        named(
            entry.item.map(Catalog.title) ?? entry.artist?.name ?? entry.album?.title ?? entry.song?.title
                ?? entry.collection?.name ?? "", edition: entry.editionName)
    }

    public static func named(_ title: String, edition: String?) -> String {
        edition.map { "\(title) · \($0)" } ?? title
    }

    /// What the entry stands for: a container counts what it plays now.
    public static func detail(_ entry: PlaylistEntry) -> String {
        let show = entry.show.map(Catalog.title)
        let parts: [String?] =
            switch entry.kind {
            case .movie: [Format.runtime(minutes: minutes(entry.durationMs))]
            case .show: [Format.count(entry.itemCount, "episode")]
            case .season: [show, Format.count(entry.itemCount, "episode")]
            case .episode: [show, entry.item.map(Format.episodeCode)]
            case .artist: [Format.count(entry.itemCount, "song")]
            case .album: [entry.album?.artistName, Format.count(entry.itemCount, "song")]
            case .song: [entry.song?.artistName, entry.song?.albumTitle]
            case .collection: [Format.count(entry.itemCount, "movie")]
            }
        return parts.compactMap { $0 }.joined(separator: " · ")
    }

    private static func minutes(_ ms: Int64) -> Int { Int((ms + 30_000) / 60_000) }
}
