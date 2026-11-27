import Foundation
import GRDB
import RabbitEarsAPI

public typealias MusicArtist = Components.Schemas.MusicArtist
public typealias MusicAlbum = Components.Schemas.MusicAlbum
public typealias MusicSong = Components.Schemas.MusicSong
public typealias MusicRecent = Components.Schemas.MusicRecent
public typealias MusicLetterCount = Components.Schemas.MusicLetterCount
public typealias MusicSearchResult = Components.Schemas.MusicSearchResult
public typealias MusicAlbumSort = Components.Schemas.MusicAlbumSort
public typealias MusicSongSort = Components.Schemas.MusicSongSort

extension MusicAlbumSort {
    /// The Sort menu's name for it.
    public var title: String {
        switch self {
        case .title: "Title"
        case .artist: "Artist"
        case .year: "Year"
        case .added: "Recently added"
        }
    }
}

extension MusicSongSort {
    /// The Sort menu's name for it.
    public var title: String {
        switch self {
        case .added: "Recently added"
        case .title: "Title"
        case .artist: "Artist"
        case .album: "Album"
        case .popular: "Popular"
        }
    }
}

/// The Music screen's tabs, in tab order.
public enum MusicTab: String, CaseIterable, Sendable {
    case albums = "Albums"
    case artists = "Artists"
    case songs = "Songs"
    case playlists = "Playlists"
    case stations = "Stations"
}

/// Artist: the header, Popular (the five most played) and the albums, newest first.
public struct ArtistDetail: Equatable, Sendable {
    public let artist: MusicArtist
    public let popular: [MusicSong]
    public let albums: [MusicAlbum]
}

/// Album: the header, its songs in disc then track order, and More by the artist.
public struct AlbumDetail: Equatable, Sendable {
    public let album: MusicAlbum
    public let songs: [MusicSong]
    public let moreByArtist: [MusicAlbum]
    /// Track numbers restart per disc, so the list groups by disc.
    public var discs: [Int] { Array(Set(songs.map { $0.discNumber ?? 1 })).sorted() }
}

/// Music Home: Recently played (albums and music playlists) and Recently added albums.
public struct MusicHome: Equatable, Sendable {
    public let recentlyPlayed: [MusicRecent]
    public let recentlyAdded: [MusicAlbum]
}

/// Reads the music catalog for the active profile from the replica, as
/// the server's views let it hear; what reads the profile's plays asks the
/// server.
@MainActor
public final class MusicModel {
    public let client: Client
    public let replica: Replica
    public let profileId: Int64

    public init(client: Client, replica: Replica, profileId: Int64) {
        self.client = client
        self.replica = replica
        self.profileId = profileId
    }

    public func home(limit: Int = 20) async throws -> MusicHome {
        async let played = recentlyPlayed(limit: limit)
        let added = try await albums(sort: .added, limit: limit).items
        return MusicHome(recentlyPlayed: try await played, recentlyAdded: added)
    }

    /// Without a kind, albums and music playlists mixed; with one, CarPlay's
    /// 12 most recent for a limited list. Online only: plays are not in the replica.
    public func recentlyPlayed(
        kind: Components.Schemas.MusicRecentKind? = nil, limit: Int = 20
    ) async throws -> [MusicRecent] {
        try await call {
            try await client.listRecentlyPlayedMusic(
                path: .init(profileId: profileId), query: .init(kind: kind, limit: limit)
            ).ok.body.json.items
        }
    }

    public func albums(
        sort: MusicAlbumSort = .title, genreId: Int64? = nil, letter: String? = nil, offset: Int? = nil,
        limit: Int = 100
    ) async throws -> Components.Schemas.MusicAlbumPage {
        let filter = MusicRows.Filter(
            genreId: genreId, letter: letter, sort: sort.rawValue, limit: limit, offset: offset ?? 0)
        return try await read { db, me in
            let (items, next) = try MusicRows.albums(db, me, filter)
            return .init(items: items, nextOffset: next, total: try MusicRows.countAlbums(db, me, filter))
        }
    }

    public func artists(
        genreId: Int64? = nil, letter: String? = nil, offset: Int? = nil, limit: Int = 100
    ) async throws -> Components.Schemas.MusicArtistPage {
        let filter = MusicRows.Filter(genreId: genreId, letter: letter, limit: limit, offset: offset ?? 0)
        return try await read { db, me in
            let (items, next) = try MusicRows.artists(db, me, filter)
            return .init(items: items, nextOffset: next, total: try MusicRows.countArtists(db, me, filter))
        }
    }

    public func songs(
        sort: MusicSongSort = .title, genreId: Int64? = nil, offset: Int? = nil, limit: Int = 100
    ) async throws -> Components.Schemas.MusicSongPage {
        let filter = MusicRows.Filter(genreId: genreId, sort: sort.rawValue, limit: limit, offset: offset ?? 0)
        return try await read { db, me in
            let (items, next) = try MusicRows.songs(db, me, filter)
            return .init(items: items, nextOffset: next, total: try MusicRows.countSongs(db, me, filter))
        }
    }

    /// Popular, the most played across every profile, is online only: plays are not in the replica.
    public func artist(_ id: Int64) async throws -> ArtistDetail {
        let (artist, albums) = try await read { db, me in
            (
                try found(MusicRows.artists(db, me, .init(id: id)).0),
                try MusicRows.albums(db, me, .init(artistId: id, sort: "year", limit: MusicRows.Filter.all)).0
            )
        }
        let popular = try await call {
            try await client.listMusicSongs(query: .init(artistId: id, sort: .popular, limit: 5)).ok.body.json.items
        }
        return ArtistDetail(artist: artist, popular: popular, albums: albums)
    }

    public func album(_ id: Int64) async throws -> AlbumDetail {
        try await read { db, me in
            let album = try found(MusicRows.albums(db, me, .init(id: id)).0)
            let songs = try MusicRows.songs(db, me, .init(albumId: id, limit: MusicRows.Filter.all)).0
            let more = try MusicRows.albums(db, me, .init(artistId: album.artistId, sort: "year", limit: 21)).0
            return AlbumDetail(album: album, songs: songs, moreByArtist: more.filter { $0.id != id })
        }
    }

    /// Every song an artist plays, album by album, for Play and Shuffle on Artist.
    public func songs(byArtist id: Int64) async throws -> [MusicSong] {
        try await read { db, me in
            try MusicRows.songs(db, me, .init(artistId: id, sort: "album", limit: MusicRows.Filter.all)).0
        }
    }

    /// Letters A to Z then #, each with how many albums or artists it files.
    public func letters(of group: Components.Schemas.MusicLetterGroup) async throws -> [MusicLetterCount] {
        try await read { db, me in try MusicRows.letters(db, me, kind: group == .artists ? "artist" : "album") }
    }

    public func search(_ query: String, limit: Int = 20) async throws -> MusicSearchResult {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return MusicSearchResult(artists: [], albums: [], songs: []) }
        let filter = MusicRows.Filter(query: String(query.prefix(200)), limit: limit)
        return try await read { db, me in
            MusicSearchResult(
                artists: try MusicRows.artists(db, me, filter).0, albums: try MusicRows.albums(db, me, filter).0,
                songs: try MusicRows.songs(db, me, filter).0)
        }
    }

    func read<T: Sendable>(_ body: @escaping @Sendable (Database, Int64) throws -> T) async throws -> T {
        let profile = profileId
        return try await call { try await replica.read { try body($0, profile) } }
    }

    private func call<T>(_ body: () async throws -> T) async throws -> T {
        do { return try await body() } catch { throw AppError.from(error, unauthorized: .signedOut) }
    }
}

/// What a by-id read of the replica found, or the server's not found.
func found<T>(_ rows: [T]) throws -> T {
    guard let first = rows.first else { throw AppError.server("not found") }
    return first
}

/// Every page of a paged listing, in order.
nonisolated(nonsending) func allPages<T>(_ fetch: (Int?) async throws -> ([T], Int?)) async throws -> [T] {
    var all: [T] = []
    var offset: Int?
    repeat {
        let (items, next) = try await fetch(offset)
        all += items
        offset = next
    } while offset != nil
    return all
}

extension Format {
    /// An ffprobe codec name as listeners know it: flac is FLAC, pcm_s16le is PCM.
    public static func codec(_ name: String) -> String {
        String(name.split(separator: "_").first ?? Substring(name)).uppercased()
    }

    /// A song count and total length: `10 songs · 42m`.
    public static func songs(_ count: Int, durationMs: Int64) -> String {
        let songs = Format.count(count, "song")
        return "\(songs) · \(runtime(minutes: Int((durationMs + 30_000) / 60_000)))"
    }
}
