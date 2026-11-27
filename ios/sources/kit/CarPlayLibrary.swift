import Foundation
import RabbitEarsAPI

/// Builds every CarPlay list from the music catalog. Each throws AppError;
/// `.unreachable` means the server is gone and the scene shows so.
@MainActor
public final class CarPlayLibrary {
    private let music: MusicModel
    private let stations: StationsModel

    public init(music: MusicModel, stations: StationsModel) {
        self.music = music
        self.stations = stations
    }

    /// Recently played (albums and playlists) and Recently added; each row plays.
    public func recent(_ limits: CarPlayLimits) async throws -> CarPlayList {
        let home = try await music.home()
        let played = home.recentlyPlayed.compactMap(Self.recentRow)
        let added = home.recentlyAdded.map { Self.albumRow($0, detail: $0.artistName, action: .play(.album($0.id))) }
        let sections = [("Recently played", played), ("Recently added", added)].filter { !$0.1.isEmpty }
            .map { CarPlaySection(header: $0.0, index: nil, rows: $0.1) }
        return CarPlayList(sections: sections, empty: sections.isEmpty ? .noMusic : nil).capped(limits)
    }

    public func albums(_ limits: CarPlayLimits) async throws -> CarPlayList {
        try await index(.albums, limits)
    }

    public func artists(_ limits: CarPlayLimits) async throws -> CarPlayList {
        try await index(.artists, limits)
    }

    public func playlists(_ limits: CarPlayLimits) async throws -> CarPlayList {
        let playlists = try await music.read { db, me in try PlaylistRows.playlists(db, profile: me) }
        let rows = playlists.filter { $0.kind == .music }.map {
            Self.playlistRow($0, detail: Format.count($0.itemCount, "song"))
        }
        let onAir = StationsModel.onNow(await stations.list(.music) ?? []).map(Self.stationRow)
        if !onAir.isEmpty {
            return CarPlayList(
                sections: [("Stations", onAir), ("Playlists", rows)].filter { !$0.1.isEmpty }
                    .map { CarPlaySection(header: $0.0, index: nil, rows: $0.1) }
            ).capped(limits)
        }
        guard rows.isEmpty else {
            return CarPlayList(sections: [CarPlaySection(header: nil, index: nil, rows: rows)]).capped(limits)
        }
        let library = try await music.letters(of: .albums)
        return CarPlayList(sections: [], empty: library.isEmpty ? .noMusic : .noPlaylists)
    }

    /// The albums or artists filed under one letter row.
    public func letter(
        _ group: MusicLetterGroup, _ letter: String, _ limits: CarPlayLimits
    ) async throws -> CarPlayList {
        let rows = try await everything(group, letter: letter).prefix(limits.maxItems)
        return CarPlayList(title: letter, sections: [CarPlaySection(header: nil, index: nil, rows: Array(rows))])
    }

    /// Albums only, newest first; Play replaces Popular.
    public func artist(_ id: Int64, _ limits: CarPlayLimits) async throws -> CarPlayList {
        let detail = try await music.artist(id)
        let artist = detail.artist
        let rows = detail.albums.map {
            Self.albumRow($0, detail: $0.year.map(String.init), action: .open(.album($0.id)))
        }
        return CarPlayList(
            title: "Artist",
            header: CarPlayHeader(
                art: .round(id), title: artist.name,
                subtitle:
                    "\(Format.count(artist.albumCount, "album")) \u{B7} \(Format.count(artist.songCount, "song"))",
                play: .artist(id, name: artist.name)),
            sections: [CarPlaySection(header: nil, index: nil, rows: rows)]
        ).capped(limits)
    }

    /// Tracks by title only, in disc then track order.
    public func album(_ id: Int64, _ limits: CarPlayLimits) async throws -> CarPlayList {
        let detail = try await music.album(id)
        let album = detail.album
        let rows = detail.songs.enumerated().map { index, song in
            CarPlayRow(
                text: song.title, detail: nil, art: nil, action: .playTrack(index),
                marker: .song(song.id))
        }
        return CarPlayList(
            title: "Album",
            header: CarPlayHeader(
                art: .square(id), title: album.title,
                subtitle: ([album.artistName] + [album.year.map(String.init)].compactMap { $0 }).joined(
                    separator: " \u{B7} "), play: .album(id)),
            sections: [CarPlaySection(header: nil, index: nil, rows: rows)],
            queue: CarPlayQueue(songs: detail.songs, source: album.title, playlistId: nil)
        ).capped(limits)
    }

    public func playlist(_ id: Int64, _ limits: CarPlayLimits) async throws -> CarPlayList {
        let (playlist, queue) = try await playlistQueue(id)
        let rows = queue.songs.enumerated().map { index, song in
            CarPlayRow(
                text: song.title, detail: song.artistName, art: .square(song.albumId),
                action: .playTrack(index), marker: .song(song.id))
        }
        return CarPlayList(
            title: playlist.name,
            header: CarPlayHeader(
                art: Self.art(playlist), title: playlist.name,
                subtitle: Format.count(playlist.itemCount, "song"), play: .playlist(id)),
            sections: [CarPlaySection(header: nil, index: nil, rows: rows)], queue: queue
        ).capped(limits)
    }

    /// The songs Play, Shuffle or a Recent row starts.
    public func queue(for playable: CarPlayPlayable) async throws -> CarPlayQueue {
        switch playable {
        case .album(let id):
            let detail = try await music.album(id)
            return CarPlayQueue(songs: detail.songs, source: detail.album.title, playlistId: nil)
        case .artist(let id, let name):
            return CarPlayQueue(songs: try await music.songs(byArtist: id), source: name, playlistId: nil)
        case .playlist(let id):
            return try await playlistQueue(id).1
        }
    }

    /// The upcoming songs; a tap plays one. No reorder or Clear in the car.
    public static func upNext(_ queue: AudioQueue, maxItems: Int) -> CarPlayList {
        let rows = queue.upNext.prefix(maxItems).map { entry in
            CarPlayRow(
                text: entry.song.title, detail: entry.song.artistName, art: .square(entry.song.albumId),
                action: .jump(entry.id), marker: nil)
        }
        return CarPlayList(title: "Up next", sections: [CarPlaySection(header: nil, index: nil, rows: rows)])
    }

    /// A station plays in the server's order, so neither shuffle nor repeat means anything while one is tuned.
    public static func nowPlayingButtons(station: Bool) -> [CarPlayNowPlayingButton] {
        station ? [] : [.shuffle, .repeatMode]
    }

    /// CarPlay allows five templates; Up next would be a sixth after a fifth Now Playing.
    public static func upNextEnabled(depth: Int) -> Bool { depth < 5 }

    /// A to Z by the first letter, a leading "The" and accents ignored; anything else is #.
    public static func letter(_ name: String) -> String {
        var name = Substring(name)
        if name.lowercased().hasPrefix("the ") { name = name.dropFirst(4) }
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).uppercased()
        guard let first = folded.first, first.isASCII, first.isLetter else { return "#" }
        return String(first)
    }

    /// Albums and Artists: one list A to Z while it fits, else a row per
    /// letter; a car that limits lists gets the most recently played.
    private func index(_ group: MusicLetterGroup, _ limits: CarPlayLimits) async throws -> CarPlayList {
        if limits.limited {
            let kind: Components.Schemas.MusicRecentKind = group == .albums ? .album : .artist
            let rows = try await music.recentlyPlayed(kind: kind, limit: 12).compactMap(Self.openRow)
            return CarPlayList(sections: [CarPlaySection(header: nil, index: nil, rows: rows)])
        }
        let letters = try await music.letters(of: group)
        guard !letters.isEmpty else { return CarPlayList(sections: [], empty: .noMusic) }
        let total = letters.reduce(0) { $0 + $1.count }
        guard total <= limits.maxItems, letters.count <= limits.maxSections else {
            let noun = group == .albums ? "album" : "artist"
            let rows = letters.map {
                CarPlayRow(
                    text: $0.letter, detail: Format.count($0.count, noun), art: nil,
                    action: .open(.letter(group, $0.letter)), marker: nil)
            }
            return CarPlayList(sections: [CarPlaySection(header: nil, index: nil, rows: rows)])
        }
        let rows = try await everything(group, letter: nil)
        let filed = Dictionary(grouping: rows) { Self.letter($0.text) }
        let order = "ABCDEFGHIJKLMNOPQRSTUVWXYZ#".map(String.init)
        return CarPlayList(
            sections: order.compactMap { letter in
                filed[letter].map { CarPlaySection(header: letter, index: letter, rows: $0) }
            })
    }

    private func everything(_ group: MusicLetterGroup, letter: String?) async throws -> [CarPlayRow] {
        switch group {
        case .albums:
            let albums = try await call {
                try await allPages { offset in
                    let page = try await self.music.albums(sort: .title, letter: letter, offset: offset, limit: 200)
                    return (page.items, page.nextOffset)
                }
            }
            return albums.map { Self.albumRow($0, detail: $0.artistName, action: .open(.album($0.id))) }
        case .artists:
            let artists = try await call {
                try await allPages { offset in
                    let page = try await self.music.artists(letter: letter, offset: offset, limit: 200)
                    return (page.items, page.nextOffset)
                }
            }
            return artists.map(Self.artistRow)
        }
    }

    /// One the profile neither owns nor is reached by is not found.
    private func playlistQueue(_ id: Int64) async throws -> (Playlist, CarPlayQueue) {
        let (playlist, rows) = try await music.read { db, me in
            (
                try found([PlaylistRows.playlist(db, profile: me, id: id)].compactMap { $0 }),
                try PlaylistRows.playOrder(db, profile: me, playlist: id)
            )
        }
        return (playlist, CarPlayQueue(songs: rows.songs, source: playlist.name, playlistId: id))
    }

    private func call<T>(_ body: () async throws -> T) async throws -> T {
        do { return try await body() } catch { throw AppError.from(error, unauthorized: .signedOut) }
    }

    private static func albumRow(_ album: MusicAlbum, detail: String?, action: CarPlayAction) -> CarPlayRow {
        CarPlayRow(
            text: album.title, detail: detail, art: .square(album.id), action: action, marker: .album(album.id))
    }

    private static func artistRow(_ artist: MusicArtist) -> CarPlayRow {
        CarPlayRow(
            text: artist.name, detail: nil, art: .round(artist.id), action: .open(.artist(artist.id)),
            marker: nil)
    }

    private static func playlistRow(_ playlist: Playlist, detail: String) -> CarPlayRow {
        CarPlayRow(
            text: playlist.name, detail: detail, art: Self.art(playlist),
            action: .open(.playlist(playlist.id)), marker: nil)
    }

    /// A playlist's own image, else its first entry's.
    private static func art(_ playlist: Playlist) -> CarPlayRow.Art? {
        playlist.imageUrl.map { .custom($0) } ?? playlist.artItemId.map { .square($0) }
    }

    /// A station's row tunes in; its art is its own image, else the album of what is on, else next.
    private static func stationRow(_ station: Station) -> CarPlayRow {
        CarPlayRow(
            text: station.name, detail: StationText.lines(station.onAir, kind: .music).first,
            art: station.imageUrl.map { .custom($0) }
                ?? StationText.art(station.onAir)?.song.map { .square($0.albumId) },
            action: .tune(station),
            marker: nil)
    }

    /// A Recent row, which plays at once.
    private static func recentRow(_ recent: MusicRecent) -> CarPlayRow? {
        if let album = recent.album {
            return albumRow(album, detail: album.artistName, action: .play(.album(album.id)))
        }
        if let playlist = recent.playlist {
            return CarPlayRow(
                text: playlist.name, detail: "Playlist \u{B7} \(Format.count(playlist.itemCount, "song"))",
                art: Self.art(playlist), action: .play(.playlist(playlist.id)),
                marker: nil)
        }
        return recent.artist.map {
            CarPlayRow(
                text: $0.name, detail: nil, art: .round($0.id),
                action: .play(.artist($0.id, name: $0.name)), marker: nil)
        }
    }

    /// A limited list's row, which opens as on the full list.
    private static func openRow(_ recent: MusicRecent) -> CarPlayRow? {
        if let album = recent.album {
            return albumRow(album, detail: album.artistName, action: .open(.album(album.id)))
        }
        return recent.artist.map(artistRow)
    }
}
