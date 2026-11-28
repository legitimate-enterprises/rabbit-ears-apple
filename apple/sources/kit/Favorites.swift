import Foundation
import GRDB
import Observation
import RabbitEarsAPI

public typealias FavoriteKind = Components.Schemas.FavoriteKind

/// A favorites screen's sections, in the order shown; each shows only when it has a title.
public enum FavoriteSection: String, CaseIterable, Sendable, Hashable {
    case movies = "Movies"
    case shows = "Shows"
    case seasons = "Seasons"
    case episodes = "Episodes"
    case artists = "Artists"
    case albums = "Albums"
    case songs = "Songs"
    case videos = "Videos"

    public var kind: FavoriteKind {
        switch self {
        case .movies: .movie
        case .shows: .show
        case .seasons: .season
        case .episodes: .episode
        case .artists: .artist
        case .albums: .album
        case .songs: .song
        case .videos: .video
        }
    }

    init(_ kind: FavoriteKind) { self = Self.allCases.first { $0.kind == kind }! }
}

/// A profile's favorites of what it browses, each list most recently starred first.
public struct FavoriteShelves: Sendable {
    public var movies: [Item] = []
    public var shows: [Item] = []
    public var seasons: [Item] = []
    public var episodes: [Item] = []
    public var artists: [MusicArtist] = []
    public var albums: [MusicAlbum] = []
    public var songs: [MusicSong] = []
    public var videos: [YouTubeVideo] = []

    public init() {}

    public var sections: [FavoriteSection] {
        FavoriteSection.allCases.filter { count($0) > 0 }
    }

    public func count(_ section: FavoriteSection) -> Int {
        switch section {
        case .movies: movies.count
        case .shows: shows.count
        case .seasons: seasons.count
        case .episodes: episodes.count
        case .artists: artists.count
        case .albums: albums.count
        case .songs: songs.count
        case .videos: videos.count
        }
    }
}

/// The active profile's stars, read once and observed, so a star or a menu
/// shows its state without a read per title. Loaded again on each commit
/// to the replica's favorites.
@MainActor
@Observable
public final class Favorites {
    /// Each starred title the profile may open, by id, with its kind.
    private var starred: [UID: FavoriteKind] = [:]

    public init() {}

    public func contains(_ id: UID) -> Bool { starred[id] != nil }

    public var ids: Set<UID> { Set(starred.keys) }

    /// The kinds the profile has a star of, in section order.
    public var sections: [FavoriteSection] {
        let kinds = Set(starred.values)
        return FavoriteSection.allCases.filter { kinds.contains($0.kind) }
    }

    /// Replaces what is known with `profile`'s stars on what it may open, as
    /// a kids' title reached under Hide kids' content; a replica that cannot
    /// be read holds none.
    public func load(profile: UID, replica: Replica) async {
        let rows = try? await replica.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT f.item_id, i.kind FROM favorite f JOIN item i ON i.id = f.item_id
                    WHERE f.account_id = ?1
                        AND f.item_id IN (SELECT item_id FROM profile_item_open WHERE account_id = ?1)
                    """, arguments: [profile]
            ).compactMap { row in FavoriteKind(rawValue: row["kind"]).map { (row["item_id"] as UID, $0) } }
        }
        starred = Dictionary(rows ?? [], uniquingKeysWith: { first, _ in first })
    }

    /// `profile`'s favorites of what it browses, or of `only` that section.
    nonisolated static func shelves(_ db: Database, profile: UID, only: FavoriteSection?) throws -> FavoriteShelves {
        let starredAt = Dictionary(
            uniqueKeysWithValues: try Row.fetchAll(
                db, sql: "SELECT item_id, created_at FROM favorite WHERE account_id = ?", arguments: [profile]
            ).map { ($0["item_id"] as UID, $0["created_at"] as Int64) })
        func recent<T>(_ list: [T], _ id: (T) -> UID) -> [T] {
            list.sorted { lhs, rhs in
                let (left, right) = (starredAt[id(lhs)] ?? 0, starredAt[id(rhs)] ?? 0)
                return left != right ? left > right : id(lhs) < id(rhs)
            }
        }
        let wanted = only.map { [$0] } ?? FavoriteSection.allCases
        var shelves = FavoriteShelves()
        if !Set(wanted).isDisjoint(with: [.movies, .shows, .seasons, .episodes]) {
            let items = recent(
                try ReplicaRows.items(
                    db,
                    "i.id IN (SELECT item_id FROM favorite WHERE account_id = ?)"
                        + " AND i.id IN (SELECT item_id FROM profile_item WHERE account_id = ?)", [profile, profile],
                    for: profile),
                \.id)
            let of = { (kind: ItemKind, section: FavoriteSection) in
                wanted.contains(section) ? items.filter { $0.kind == kind } : []
            }
            shelves.movies = of(.movie, .movies)
            shelves.shows = of(.show, .shows)
            shelves.seasons = of(.season, .seasons)
            shelves.episodes = of(.episode, .episodes)
        }
        var music = MusicRows.Filter(limit: MusicRows.Filter.all)
        music.favorites = true
        if wanted.contains(.artists) { shelves.artists = recent(try MusicRows.artists(db, profile, music).0, \.id) }
        if wanted.contains(.albums) { shelves.albums = recent(try MusicRows.albums(db, profile, music).0, \.id) }
        if wanted.contains(.songs) { shelves.songs = recent(try MusicRows.songs(db, profile, music).0, \.id) }
        if wanted.contains(.videos) {
            var videos = YouTubeRows.VideoFilter(limit: MusicRows.Filter.all)
            videos.favorites = true
            shelves.videos = recent(try YouTubeRows.videos(db, profile, videos).0, \.id)
        }
        return shelves
    }
}

extension AppModel {
    /// The active profile's stars, from the replica.
    public func loadFavorites() async {
        guard let replica = sync?.replica, let profile = activeProfile?.id else { return }
        await favorites.load(profile: profile, replica: replica)
    }

    /// Stars or unstars a title for the active profile, here at once and on
    /// the server when it is reached; a failure is told as a notice.
    public func setFavorite(_ on: Bool, _ id: UID) async {
        guard let sync, let profile = activeProfile?.id else { return }
        do {
            if on {
                try await sync.queue.putFavorite(item: id, as: profile)
            } else {
                try await sync.queue.deleteFavorite(item: id, as: profile)
            }
        } catch {
            live.say(AppError.from(error, unauthorized: .signedOut).localizedDescription)
        }
        await loadFavorites()
    }

    /// The active profile's favorites, or of `only` that section; nil before the first snapshot.
    public func favoriteShelves(only: FavoriteSection? = nil) async -> FavoriteShelves? {
        guard let replica = sync?.replica, let profile = activeProfile?.id else { return nil }
        return try? await replica.read { try Favorites.shelves($0, profile: profile, only: only) }
    }
}
