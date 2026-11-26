import Foundation
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

/// Reads the music catalog for the active profile. The server leaves out
/// what a kid may not hear, so nothing here checks the profile kind.
@MainActor
public final class MusicModel {
    public let client: Client
    public let profileId: Int64

    public init(client: Client, profileId: Int64) {
        self.client = client
        self.profileId = profileId
    }

    public func home(limit: Int = 20) async throws -> MusicHome {
        try await call {
            async let played = recentlyPlayed(limit: limit)
            async let added = client.listMusicAlbums(query: .init(sort: .added, limit: limit)).ok.body.json.items
            return MusicHome(recentlyPlayed: try await played, recentlyAdded: try await added)
        }
    }

    /// Without a kind, albums and music playlists mixed; with one, CarPlay's
    /// 12 most recent for a limited list.
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
        try await call {
            try await client.listMusicAlbums(
                query: .init(genreId: genreId, letter: letter, sort: sort, limit: limit, offset: offset)
            ).ok.body.json
        }
    }

    public func artists(
        genreId: Int64? = nil, letter: String? = nil, offset: Int? = nil, limit: Int = 100
    ) async throws -> Components.Schemas.MusicArtistPage {
        try await call {
            try await client.listMusicArtists(
                query: .init(genreId: genreId, letter: letter, limit: limit, offset: offset)
            ).ok.body.json
        }
    }

    public func songs(
        sort: MusicSongSort = .title, genreId: Int64? = nil, offset: Int? = nil, limit: Int = 100
    ) async throws -> Components.Schemas.MusicSongPage {
        try await call {
            try await client.listMusicSongs(query: .init(genreId: genreId, sort: sort, limit: limit, offset: offset))
                .ok.body.json
        }
    }

    public func artist(_ id: Int64) async throws -> ArtistDetail {
        try await call {
            async let artist = client.getMusicArtist(path: .init(artistId: id)).ok.body.json
            async let popular = client.listMusicSongs(query: .init(artistId: id, sort: .popular, limit: 5))
                .ok.body.json.items
            async let albums = allPages { offset in
                let page = try await self.client.listMusicAlbums(
                    query: .init(artistId: id, sort: .year, limit: 200, offset: offset)
                ).ok.body.json
                return (page.items, page.nextOffset)
            }
            return ArtistDetail(artist: try await artist, popular: try await popular, albums: try await albums)
        }
    }

    public func album(_ id: Int64) async throws -> AlbumDetail {
        try await call {
            let album = try await client.getMusicAlbum(path: .init(albumId: id)).ok.body.json
            async let songs = allPages { offset in
                let page = try await self.client.listMusicSongs(
                    query: .init(albumId: id, limit: 200, offset: offset)
                ).ok.body.json
                return (page.items, page.nextOffset)
            }
            async let more = client.listMusicAlbums(query: .init(artistId: album.artistId, sort: .year, limit: 21))
                .ok.body.json.items
            return AlbumDetail(
                album: album, songs: try await songs, moreByArtist: try await more.filter { $0.id != id })
        }
    }

    /// Every song an artist plays, album by album, for Play and Shuffle on Artist.
    public func songs(byArtist id: Int64) async throws -> [MusicSong] {
        try await call {
            try await allPages { offset in
                let page = try await self.client.listMusicSongs(
                    query: .init(artistId: id, sort: .album, limit: 200, offset: offset)
                ).ok.body.json
                return (page.items, page.nextOffset)
            }
        }
    }

    /// Letters A to Z then #, each with how many albums or artists it files.
    public func letters(of group: Components.Schemas.MusicLetterGroup) async throws -> [MusicLetterCount] {
        try await call { try await client.listMusicLetters(query: .init(of: group)).ok.body.json.items }
    }

    public func search(_ query: String, limit: Int = 20) async throws -> MusicSearchResult {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return MusicSearchResult(artists: [], albums: [], songs: []) }
        return try await call {
            try await client.searchMusic(query: .init(q: String(query.prefix(200)), limit: limit)).ok.body.json
        }
    }

    private func call<T>(_ body: () async throws -> T) async throws -> T {
        do { return try await body() } catch { throw AppError.from(error, unauthorized: .signedOut) }
    }
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
