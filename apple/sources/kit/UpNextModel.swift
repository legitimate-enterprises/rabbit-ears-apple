import Foundation
import GRDB
import Observation
import RabbitEarsAPI

/// What plays when a movie, episode or video ends, as the server would
/// answer it, and Autoplay's countdown to it.
@MainActor
@Observable
public final class UpNextModel {
    public static let countdownSeconds = 10

    /// What the card names: "Up next: \(title)".
    public let title: String
    /// What Play now plays, in the player already open.
    public let request: PlayRequest
    public private(set) var autoplay: Bool
    /// Seconds before the next item plays by itself; nil while Autoplay is off.
    public private(set) var secondsLeft: Int?

    init(title: String, request: PlayRequest, autoplay: Bool) {
        self.title = title
        self.request = request
        self.autoplay = autoplay
    }

    /// What follows `ended` for the profile, as getUpNext answers: nil for
    /// nothing, a title it may not see, an unread replica, or a Watch
    /// together, which only closes.
    public static func load(after ended: PlayRequest, replica: Replica, profile: Account) async -> UpNextModel? {
        let (id, queue, profileId) = (ended.item.id, ended.queue, profile.id)
        guard ended.together == nil,
            let next = try? await replica.read({ try Self.next(after: id, in: queue, profileId, $0) })
        else { return nil }
        let request =
            if let index = next.index, let queue = ended.queue?.at(index) {
                PlayRequest(id: ended.id, item: queue.current, editionId: queue.editionId, positionMs: 0, queue: queue)
            } else {
                PlayRequest(id: ended.id, item: next.item, editionId: next.editionId, positionMs: 0)
            }
        return UpNextModel(title: next.title, request: request, autoplay: profile.autoplay ?? true)
    }

    private struct Next {
        let item: Item
        var title: String
        var editionId: Int64?
        var index: Int?
    }

    /// From a playlist its next row, otherwise the episode, film or video
    /// after the item. Only what has a file on disk counts.
    private nonisolated static func next(
        after id: Item.ID, in queue: VideoQueue?, _ profile: Int64, _ db: Database
    ) throws -> Next? {
        guard
            try Bool.fetchOne(
                db, sql: "SELECT 1 FROM item WHERE id = ? AND id " + ReplicaRows.seenBy,
                arguments: [id, profile]) == true
        else { return nil }
        guard let queue else {
            let from: (String, String)? =
                switch try String.fetchOne(db, sql: "SELECT kind FROM item WHERE id = ?", arguments: [id]) {
                case "episode": (ReplicaRows.showEpisodes, ReplicaRows.episodeOrder)
                case "movie": (ReplicaRows.franchise, ReplicaRows.collectionOrder)
                case "video": (ReplicaRows.channelVideos, ReplicaRows.videoOrder)
                default: nil
                }
            guard let from, let next = try ReplicaRows.next(db, from: from.0, order: from.1, after: id, seenBy: profile)
            else { return nil }
            return try titled(next, db)
        }
        return try nextRow(after: id, in: queue, profile, db)
    }

    /// NextRow: the row after `queue`'s index of its play order the profile
    /// may see, else after the item's first row, skipping rows with no file on disk.
    private nonisolated static func nextRow(
        after id: Item.ID, in queue: VideoQueue, _ profile: Int64, _ db: Database
    ) throws -> Next? {
        guard
            try Bool.fetchOne(
                db,
                sql: """
                    SELECT 1 FROM playlist p WHERE p.id = ?1 AND (p.account_id = ?2
                        OR EXISTS (SELECT 1 FROM playlist_reach r WHERE r.playlist_id = p.id AND r.account_id = ?2))
                    """, arguments: [queue.playlistId, profile]) == true
        else { return nil }
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT r.item_id, r.edition_id, \(ReplicaRows.unavailable("r.item_id")) AS gone FROM playlist_row r
                WHERE r.playlist_id = ? AND r.item_id \(ReplicaRows.seenBy) ORDER BY r.seq
                """, arguments: [queue.playlistId, profile])
        let ids = rows.map { $0["item_id"] as Int64 }
        guard
            let at = ids.indices.contains(queue.index) && ids[queue.index] == id ? queue.index : ids.firstIndex(of: id),
            let index = rows.indices.dropFirst(at + 1).first(where: { !rows[$0]["gone"] }),
            var next = try titled(ids[index], db)
        else { return nil }
        let edition: Int64 = rows[index]["edition_id"]
        if edition != 0 {
            next.editionId = edition
            let cuts = try Editions.cuts(ids[index], db)
            if cuts.filter({ $0.files > 0 }).count > 1, let name = cuts.first(where: { $0.id == edition })?.name {
                next.title += " · " + name
            }
        }
        next.index = index
        return next
    }

    /// The item with the card's title: a movie's or video's own, an episode's as `Show · S1 E2 · Title`.
    private nonisolated static func titled(_ id: Item.ID, _ db: Database) throws -> Next? {
        if let video = try Row.fetchOne(
            db,
            sql: """
                SELECT v.id, v.library_id, v.parent_id, c.parsed_title AS channel, v.parsed_title, v.added_at,
                    (SELECT ms.overview FROM item_shown ms WHERE ms.item_id = v.id) AS overview,
                    (SELECT f.duration_ms FROM item_file x JOIN media_file f ON f.id = x.media_file_id
                        WHERE x.item_id = v.id ORDER BY f.id LIMIT 1) AS duration_ms
                FROM item v JOIN item c ON c.id = v.parent_id WHERE v.id = ? AND v.kind = 'video'
                """, arguments: [id])
        {
            let video = YouTubeVideo(
                id: video["id"], libraryId: video["library_id"], channelId: video["parent_id"],
                channelTitle: video["channel"], title: video["parsed_title"], overview: video["overview"],
                durationMs: video["duration_ms"], watched: false, positionMs: 0,
                addedAt: ReplicaRows.instant(video["added_at"]))
            return Next(item: Item(video: video), title: video.title)
        }
        guard let item = try ReplicaRows.items(db, ids: [id]).first else { return nil }
        guard item.kind == .episode, let season = try ReplicaRows.items(db, ids: [item.parentId ?? 0]).first,
            let show = try ReplicaRows.items(db, ids: [season.parentId ?? 0]).first
        else { return Next(item: item, title: Catalog.title(item)) }
        return Next(
            item: item,
            title: "\(Catalog.title(show)) · S\(season.seasonNumber ?? 0) E\(item.episodeNumber ?? 0) · "
                + Catalog.title(item)
        )
    }

    /// Counts down a second at a time while Autoplay is on. True once it
    /// reaches zero; false when Autoplay is off or the wait is cancelled.
    public func countdown(tick: () async throws -> Void = { try await Task.sleep(for: .seconds(1)) }) async -> Bool {
        secondsLeft = autoplay ? Self.countdownSeconds : nil
        while autoplay, let left = secondsLeft, left > 0 {
            do { try await tick() } catch { return false }
            guard autoplay else { return false }
            secondsLeft = left - 1
        }
        return autoplay
    }

    /// Turns Autoplay on or off for the active profile on every device; a
    /// view restarts `countdown` when it changes.
    public func setAutoplay(_ on: Bool, model: AppModel) async {
        autoplay = on
        if !on { secondsLeft = nil }
        guard let profile = model.activeProfile else { return }
        try? await model.savePreferences(for: profile, color: nil, hideKidsContent: nil, autoplay: on)
    }
}
