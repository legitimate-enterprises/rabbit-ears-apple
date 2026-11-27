import Foundation
import GRDB
import Observation
import RabbitEarsAPI

public typealias Playlist = Components.Schemas.Playlist
public typealias PlaylistEntry = Components.Schemas.PlaylistEntry
public typealias PlaylistKind = Components.Schemas.PlaylistKind
public typealias PlayOrderRow = Components.Schemas.PlaylistPlayOrderItem
typealias PlaylistEntryInput = Components.Schemas.PlaylistEntryInput

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
    public let profileId: UID
    /// An adult makes and adds to playlists; a kid only has those shared with them.
    public let adult: Bool

    public init(
        client: Client, replica: Replica, queue: ActionQueue, engine: SyncEngine, profileId: UID, adult: Bool = true
    ) {
        self.client = client
        self.replica = replica
        self.queue = queue
        self.engine = engine
        self.profileId = profileId
        self.adult = adult
    }

    public func shares(of playlist: UID) -> PlaylistSharesModel {
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

    /// Queued, so it shows at once under the id made here, which the server keeps.
    @discardableResult
    public func create(name: String, kind: PlaylistKind) async -> Playlist? {
        guard let name = Self.name(name) else { return nil }
        let id = UID.new()
        var created: Playlist?
        await write {
            try await queue.createPlaylist(as: profileId, id, name: name, kind: kind)
            try await reload()
            created = playlists.first { $0.id == id }
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
    public func entries(of playlistId: UID) async -> [PlaylistEntry]? {
        var entries: [PlaylistEntry]?
        await write {
            entries = try await readPlaylist(playlistId) { db, profile in
                try PlaylistRows.entries(db, profile: profile, playlist: playlistId)
            }
        }
        return entries
    }

    /// What "Pick a title's artwork" offers from the playlist's entries; empty when none or unread.
    public func artChoices(of playlistId: UID) async -> [ArtChoice] {
        let entries = try? await readPlaylist(playlistId) { db, profile in
            try PlaylistRows.entries(db, profile: profile, playlist: playlistId)
        }
        return CustomImage.choices(entries ?? [])
    }

    /// What playing the playlist plays; nil when it could not be read.
    /// Containers are expanded as the server expands them, so this is the
    /// only source of what plays.
    public func playOrder(of playlistId: UID) async -> [PlayOrderRow]? {
        var rows: [PlayOrderRow]?
        await write {
            rows = try await readPlaylist(playlistId) { db, profile in
                try PlaylistRows.playOrder(db, profile: profile, playlist: playlistId)
            }
        }
        return rows
    }

    /// Adds an item at `position`, or last; false when refused, as the server
    /// refuses a song in a movies playlist. A title of several editions added
    /// without one is not refused: it sets `editionQuestion` and answers false.
    @discardableResult
    public func add(
        _ itemId: UID, to playlistId: UID, at position: Int? = nil, edition editionId: UID? = nil
    ) async -> Bool {
        var question: EditionQuestion?
        let added = await write {
            let picked = try await replica.read { [profileId] db -> (PlaylistEntryInput?, [Edition]) in
                let kind = try Self.kind(db, itemId, in: Self.playlist(db, profile: profileId, playlistId))
                var edition = editionId
                if edition == nil, Self.titles.contains(kind) {
                    // The server takes a title's only edition, and refuses one of several unnamed.
                    let editions = try Editions.of(itemId, db)
                    if editions.count > 1 { return (nil, editions) }
                    edition = editions.first?.id
                }
                let rank = try PlaylistRows.rank(db, playlist: playlistId, except: nil, at: position ?? .max)
                return (PlaylistEntryInput(id: .new(), itemId: itemId, rank: rank, editionId: edition), [])
            }
            if let entry = picked.0 {
                try await insert(entry, into: playlistId)
            } else {
                question = EditionQuestion(
                    itemId: itemId, playlistId: playlistId, position: position, editions: picked.1)
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

    /// Adds a collection as one entry, last; only a movies playlist takes one.
    @discardableResult
    public func add(collection collectionId: UID, to playlistId: UID) async -> Bool {
        await write {
            let entry = try await replica.read { [profileId] db in
                guard try Self.playlist(db, profile: profileId, playlistId).kind == .movies else {
                    throw AppError.server(Self.wrongKind)
                }
                return PlaylistEntryInput(
                    id: .new(), collectionId: collectionId,
                    rank: try PlaylistRows.rank(db, playlist: playlistId, except: nil, at: .max))
            }
            try await insert(entry, into: playlistId)
        }
    }

    /// Appends a selection in one request, to a playlist or a station's own;
    /// a title of several editions takes its default one. One of more
    /// entries than a queued action may touch goes to the server at once and
    /// shows after the catch-up that follows.
    @discardableResult
    public func add(_ itemIds: [UID], to playlistId: UID) async -> Bool {
        await write {
            guard !itemIds.isEmpty else { return }
            let entries = try await replica.read { [profileId] db in
                let playlist = try Self.playlist(db, profile: profileId, playlistId)
                let last = try String.fetchOne(
                    db,
                    sql: "SELECT rank FROM playlist_entry WHERE playlist_id = ? ORDER BY rank DESC, id DESC LIMIT 1",
                    arguments: [playlistId])
                let ranks = try FractionalIndex.keys(between: last, and: nil, count: itemIds.count)
                return try zip(itemIds, ranks).map { itemId, rank in
                    let kind = try Self.kind(db, itemId, in: playlist)
                    let edition =
                        try Self.titles.contains(kind) ? Editions.of(itemId, db).first(where: \.isDefault)?.id : nil
                    return PlaylistEntryInput(id: .new(), itemId: itemId, rank: rank, editionId: edition)
                }
            }
            try await queue.addEntries(as: profileId, to: playlistId, entries)
            if entries.count > ActionQueue.touchedLimit { try await caughtUp() } else { try await reload() }
        }
    }

    private func insert(_ entry: PlaylistEntryInput, into playlistId: UID) async throws {
        try await queue.addEntry(as: profileId, to: playlistId, entry)
        try await reload()
    }

    /// The kinds of item whose entry plays one edition.
    private nonisolated static let titles: Set<String> = ["movie", "episode", "song"]
    private nonisolated static let wrongKind = "The item does not belong in this kind of playlist."

    /// The playlist the profile may add to, as the server refuses one it may only read; one it cannot see is not found.
    private nonisolated static func playlist(_ db: Database, profile: UID, _ id: UID) throws -> Playlist {
        guard let playlist = try PlaylistRows.playlist(db, profile: profile, id: id) else {
            throw AppError.server("not found")
        }
        guard playlist.isEditable else { throw AppError.server("Your access to this playlist does not allow that.") }
        return playlist
    }

    /// The kind of an item the playlist holds, as service.Holds decides.
    private nonisolated static func kind(_ db: Database, _ item: UID, in playlist: Playlist) throws -> String {
        guard let kind = try String.fetchOne(db, sql: "SELECT kind FROM item WHERE id = ?", arguments: [item]) else {
            throw AppError.server("not found")
        }
        guard holds[playlist.kind]?.contains(kind) == true else { throw AppError.server(wrongKind) }
        return kind
    }

    private nonisolated static let holds: [PlaylistKind: Set<String>] = [
        .movies: ["movie"], .tv: ["show", "season", "episode"], .music: ["artist", "album", "song"],
    ]

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
        _ id: UID, _ body: @escaping @Sendable (Database, UID) throws -> T
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
        return name.isEmpty ? nil : name.prefix(scalars: 100)
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
    public let itemId: UID
    public let playlistId: UID
    public let position: Int?
    public let editions: [Edition]
    public var id: UID { itemId }
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
    public var artId: UID { song?.albumId ?? itemId ?? collectionId ?? id }
}

extension Array where Element == PlayOrderRow {
    public var songs: [MusicSong] { compactMap(\.song) }

    /// Where an entry's rows begin among the playable ones; nil when it
    /// stands for nothing now, as a show with no episodes.
    public func start(of entryId: UID) -> Int? {
        guard let first = firstIndex(where: { $0.entryId == entryId }) else { return nil }
        return self[..<first].filter { $0.song != nil || $0.item != nil }.count
    }
}

/// A movies or tv playlist in the video player: its movies and episodes in
/// play order and the row on screen, each row playing its own edition.
/// Ending a row plays the next.
public struct VideoQueue: Hashable, Sendable {
    public let playlistId: UID
    public let items: [Item]
    private let rows: [PlayOrderRow]
    public let index: Int

    public init?(_ rows: [PlayOrderRow], start: Int, playlistId: UID) {
        let rows = rows.filter { $0.item != nil }
        guard rows.indices.contains(start) else { return nil }
        self.rows = rows
        self.items = rows.compactMap(\.item)
        self.index = start
        self.playlistId = playlistId
    }

    public var current: Item { items[index] }
    public var editionId: UID? { rows[index].editionId }
    /// Present only while the title has more than one edition.
    public var editionName: String? { rows[index].editionName }
    public var next: VideoQueue? { VideoQueue(rows, start: index + 1, playlistId: playlistId) }
    public func at(_ row: Int) -> VideoQueue? { VideoQueue(rows, start: row, playlistId: playlistId) }
}
