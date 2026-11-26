import Foundation
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
    public let profileId: Int64
    /// An adult makes and adds to playlists; a kid only has those shared with them.
    public let adult: Bool

    public init(client: Client, profileId: Int64, adult: Bool = true) {
        self.client = client
        self.profileId = profileId
        self.adult = adult
    }

    /// Whether the profile gets a Playlists view of kind: an adult always, a
    /// kid once one of kind is shared with them.
    public func offersView(_ kind: PlaylistKind) -> Bool { adult || !playlists(kind).isEmpty }

    /// The playlists of kind an adult may add to: their own and those shared for write.
    public func editable(_ kind: PlaylistKind) -> [Playlist] {
        adult ? playlists(kind).filter(\.isEditable) : []
    }

    public func load() async {
        await write {
            playlists = try await allPages { offset in
                let page = try await self.client.listPlaylists(
                    path: .init(profileId: self.profileId), query: .init(limit: 200, offset: offset)
                ).ok.body.json
                return (page.items, page.nextOffset)
            }
        }
    }

    public func playlists(_ kind: PlaylistKind) -> [Playlist] { playlists.filter { $0.kind == kind } }

    @discardableResult
    public func create(name: String, kind: PlaylistKind) async -> Playlist? {
        guard let name = Self.name(name) else { return nil }
        var created: Playlist?
        await write {
            let playlist = try await client.createPlaylist(
                path: .init(profileId: profileId), body: .json(.init(name: name, kind: kind))
            ).created.body.json
            playlists.append(playlist)
            created = playlist
        }
        return created
    }

    public func rename(_ playlist: Playlist, to name: String) async {
        guard let name = Self.name(name) else { return }
        await write {
            replace(
                try await client.replacePlaylist(
                    path: .init(profileId: profileId, playlistId: playlist.id),
                    body: .json(.init(name: name, kind: playlist.kind))
                ).ok.body.json)
        }
    }

    /// False when the server refused, as it does while a station plays the playlist.
    @discardableResult
    public func delete(_ playlist: Playlist) async -> Bool {
        await write {
            do {
                _ = try await client.deletePlaylist(path: .init(profileId: profileId, playlistId: playlist.id))
                    .noContent
            } catch  where APIError.from(error)?.status == 409 {
                throw AppError.server(
                    "A station plays this playlist. Delete the station or give it another playlist first.")
            }
            playlists.removeAll { $0.id == playlist.id }
        }
    }

    /// The entries top to bottom; nil when they could not be read.
    public func entries(of playlistId: Int64) async -> [PlaylistEntry]? {
        var entries: [PlaylistEntry]?
        await write {
            entries = try await allPages { offset in
                let page = try await self.client.listPlaylistEntries(
                    path: .init(profileId: self.profileId, playlistId: playlistId),
                    query: .init(limit: 200, offset: offset)
                ).ok.body.json
                return (page.items, page.nextOffset)
            }
        }
        return entries
    }

    /// What playing the playlist plays, every page; nil when it could not
    /// be read. The server expands containers, so this is the only source
    /// of what plays.
    public func playOrder(of playlistId: Int64) async -> [PlayOrderRow]? {
        var rows: [PlayOrderRow]?
        await write {
            rows = try await allPages { offset in
                let page = try await self.client.listPlaylistPlayOrder(
                    path: .init(profileId: self.profileId, playlistId: playlistId),
                    query: .init(limit: 200, offset: offset)
                ).ok.body.json
                return (page.items, page.nextOffset)
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
                let editions = try await client.getItem(path: .init(itemId: itemId)).ok.body.json.editions ?? []
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

    /// Appends a selection in one request, to a playlist or a station's own;
    /// a title of several editions takes its default one.
    @discardableResult
    public func add(_ itemIds: [Int64], to playlistId: Int64) async -> Bool {
        await write {
            _ = try await client.addPlaylistEntries(
                path: .init(profileId: profileId, playlistId: playlistId),
                body: .json(.init(entries: itemIds.map { .init(itemId: $0) }))
            ).noContent
            try await refresh(playlistId)
        }
    }

    private func insert(_ input: Components.Schemas.PlaylistEntryInput, into playlistId: Int64) async throws {
        _ = try await client.addPlaylistEntry(
            path: .init(profileId: profileId, playlistId: playlistId), body: .json(input)
        ).created.body.json
        try await refresh(playlistId)
    }

    public func remove(_ entry: PlaylistEntry) async {
        await write {
            _ = try await client.removePlaylistEntry(
                path: .init(profileId: profileId, playlistId: entry.playlistId, entryId: entry.id)
            ).noContent
            try await refresh(entry.playlistId)
        }
    }

    /// Moves an entry to `position` counted from 0 at the top.
    public func move(_ entry: PlaylistEntry, to position: Int) async {
        await write {
            _ = try await client.replacePlaylistEntry(
                path: .init(profileId: profileId, playlistId: entry.playlistId, entryId: entry.id),
                body: .json(.init(itemId: entry.itemId, collectionId: entry.collectionId, position: max(0, position)))
            ).ok.body.json
            try await refresh(entry.playlistId)
        }
    }

    /// Entry counts, length and artwork change with every entry write.
    private func refresh(_ id: Int64) async throws {
        replace(try await client.getPlaylist(path: .init(profileId: profileId, playlistId: id)).ok.body.json)
    }

    private func replace(_ playlist: Playlist) {
        guard let at = playlists.firstIndex(where: { $0.id == playlist.id }) else { return }
        playlists[at] = playlist
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
