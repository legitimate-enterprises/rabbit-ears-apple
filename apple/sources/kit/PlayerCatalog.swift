import Foundation

/// What the video player reads from the catalog for the item it plays.
extension Catalog {
    public func playerTitle(_ item: Item, edition: String?) -> String {
        PlaylistText.named(show(of: item).map(Self.title) ?? Self.title(item), edition: edition)
    }

    /// "S1 E2 · Title" for an episode; nil for anything else.
    public static func playerSubtitle(_ item: Item) -> String? {
        item.kind == .episode ? "\(Format.episodeCode(item)) · \(title(item))" : nil
    }

    /// The episode after this one in viewing order. Specials (season 0)
    /// lead only to specials, so a series finale has none.
    public func nextEpisode(after item: Item) -> Item? {
        guard item.kind == .episode, let show = show(of: item) else { return nil }
        let episodes = episodes(under: show.id).filter { ($0.seasonNumber == 0) == (item.seasonNumber == 0) }
        return episodes.firstIndex { $0.id == item.id }.flatMap { episodes.dropFirst($0 + 1).first }
    }
}
