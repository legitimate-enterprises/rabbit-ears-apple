import Foundation
import RabbitEarsAPI

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
