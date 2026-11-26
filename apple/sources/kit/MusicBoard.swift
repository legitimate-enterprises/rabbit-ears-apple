import Foundation
import Observation
import RabbitEarsAPI

/// What the Music screen lists for the tab, sort and genre in view. A new
/// choice replaces the pager, so a slow answer to an old one never shows.
@MainActor
@Observable
public final class MusicBoard {
    public private(set) var albums: Pager<MusicAlbum>?
    public private(set) var artists: Pager<MusicArtist>?
    public private(set) var songs: Pager<MusicSong>?
    public private(set) var genres: [Genre] = []
    private let music: MusicModel

    public init(music: MusicModel) { self.music = music }

    public func loadGenres() async { genres = (try? await music.musicGenres()) ?? [] }

    /// Albums and Artists read on to the end so their count is whole; Songs
    /// can run to thousands and read on as the list scrolls (`loadMore`).
    /// Playlists belong to PlaylistsModel, and Stations to StationsModel.
    public func load(_ tab: MusicTab, sort: MusicAlbumSort, genre: Genre.ID?) async {
        let music = music
        switch tab {
        case .albums:
            let pager = Pager(counted: { offset in
                try await music.albums(sort: sort, genreId: genre, offset: offset, limit: 200)
            })
            await pager.loadMore()
            albums = pager
            await pager.loadAll()
        case .artists:
            let pager = Pager(counted: { offset in
                try await music.artists(genreId: genre, offset: offset, limit: 200)
            })
            await pager.loadMore()
            artists = pager
            await pager.loadAll()
        case .songs:
            let pager = Pager(counted: { offset in
                try await music.songs(genreId: genre, offset: offset, limit: 200)
            })
            await pager.loadMore()
            songs = pager
        case .playlists, .stations: break
        }
    }

    /// Re-reads the tab's rows without resetting them, so the scroll
    /// position and focus stay.
    public func refresh(_ tab: MusicTab) async {
        switch tab {
        case .albums: await albums?.refresh()
        case .artists: await artists?.refresh()
        case .songs: await songs?.refresh()
        case .playlists, .stations: break
        }
    }

    /// The count above the list: `1,210 albums`, the listing's own total from
    /// the first page; Stations is blank until they are read.
    public func caption(_ tab: MusicTab, playlists: Int, stations: Int? = nil) -> String {
        switch tab {
        case .albums: Self.count(albums, "album")
        case .artists: Self.count(artists, "artist")
        case .songs: Self.count(songs, "song")
        case .playlists: Self.plural(playlists, "playlist")
        case .stations: stations.map { Self.plural($0, "station") } ?? ""
        }
    }

    private static func count(_ pager: Pager<some Sendable>?, _ noun: String) -> String {
        guard let pager else { return "" }
        return plural(pager.count, noun) + (pager.countIsExact ? "" : "+")
    }

    private static func plural(_ count: Int, _ noun: String) -> String {
        count == 1 ? "1 \(noun)" : "\(count.formatted()) \(noun)s"
    }
}

extension MusicTab {
    /// `playlists` is what `PlaylistsModel.offersView` decides.
    public static func tabs(playlists: Bool) -> [MusicTab] {
        playlists ? allCases : allCases.filter { $0 != .playlists }
    }
}
