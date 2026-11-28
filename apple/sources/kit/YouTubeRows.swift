import Foundation
import GRDB
import RabbitEarsAPI

/// Channels and videos as the server's youtube.Repo reads them, over the
/// replica for one profile. A listing goes by what the profile browses
/// (profile_item); one asked for by id, by what it may open (profile_item_open).
enum YouTubeRows {
    enum Audience: String {
        case browse = "profile_item"
        case open = "profile_item_open"
    }

    /// Channels with videos, by title, `latest` (newest video first) or `best` (a title starting with the query
    /// first); with an id, that one, with videos or none.
    static func channels(
        _ db: Database, _ profile: UID, sort: String? = nil, id: UID? = nil, query: String? = nil,
        audience: Audience = .browse
    ) throws -> [YouTubeChannel] {
        let title = "c.parsed_title COLLATE NOCASE, c.id"
        let by = [
            "latest": "last IS NULL, last DESC, \(title)",
            "best": "instr(lower(c.parsed_title), lower(:q)) != 1, \(title)",
        ]
        return try Row.fetchAll(
            db,
            sql: """
                SELECT c.id, c.library_id, c.parsed_title, c.added_at, COALESCE(c.kids_content, 0) AS for_kids,
                    \(ReplicaRows.art("poster_url", "c.id", ":me")) AS poster_url,
                    (SELECT m.overview FROM item_shown m WHERE m.item_id = c.id) AS overview,
                    (SELECT m.external_id FROM item_shown m WHERE m.item_id = c.id) AS external_id,
                    (SELECT COUNT(*) FROM item v WHERE v.parent_id = c.id) AS video_count,
                    (SELECT COUNT(*) FROM item v WHERE v.parent_id = c.id AND NOT EXISTS (SELECT 1 FROM watch_state w
                        WHERE w.item_id = v.id AND w.account_id = :me AND w.watched = 1)) AS unwatched_count,
                    (SELECT MAX(vm.published_at) FROM item v JOIN item_metadata vm ON vm.item_id = v.id
                        AND vm.source = 'local' WHERE v.parent_id = c.id) AS last
                FROM item c
                WHERE c.kind = 'channel' AND c.id IN (SELECT item_id FROM \(audience.rawValue) WHERE account_id = :me)
                    AND (:id IS NULL AND EXISTS (SELECT 1 FROM item v WHERE v.parent_id = c.id) OR c.id = :id)
                    AND (:q IS NULL OR instr(lower(c.parsed_title), lower(:q)) > 0)
                ORDER BY \(by[sort ?? ""] ?? title)
                """, arguments: ["me": profile, "id": id, "q": query]
        ).map { row in
            let external = text(row["external_id"])
            return YouTubeChannel(
                id: row["id"], libraryId: row["library_id"], title: row["parsed_title"],
                overview: text(row["overview"]), videoCount: row["video_count"],
                unwatchedCount: row["unwatched_count"], lastVideoOn: (row["last"] as Int64?).map(day),
                externalId: external, sourceUrl: external.map(channelURL), forKids: row["for_kids"],
                addedAt: ReplicaRows.instant(row["added_at"]), posterUrl: row["poster_url"])
        }
    }

    /// youtube.VideoFilter; nil is no constraint and `sort` nil is newest.
    struct VideoFilter {
        var channelId: UID?
        var id: UID?
        var unwatched = false
        var inProgress = false
        var query: String?
        var sort: String?
        var limit = 100
        var offset = 0
        var audience = Audience.browse
    }

    /// One page of videos with the profile's watch state, and where the next starts.
    static func videos(_ db: Database, _ profile: UID, _ filter: VideoFilter) throws -> ([YouTubeVideo], Int?) {
        let newest = "COALESCE(m.published_at, 0) DESC, v.added_at DESC, v.id DESC"
        let by =
            [
                "oldest": "m.published_at IS NULL, m.published_at, v.added_at, v.id",
                "title": "v.parsed_title COLLATE NOCASE, v.id",
                "channel": "c.parsed_title COLLATE NOCASE, c.id, \(newest)",
                "length": "dur IS NULL, dur DESC, v.id",
                "played": "w.last_played_at IS NULL, w.last_played_at DESC, v.id",
                "best": "instr(lower(v.parsed_title), lower(:q)) != 1, v.parsed_title COLLATE NOCASE, v.id",
            ][filter.sort ?? ""] ?? newest
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT v.id, v.library_id, v.parent_id, c.parsed_title AS channel_title, v.parsed_title, v.added_at,
                    \(ReplicaRows.art("poster_url", "v.id", ":me")) AS poster_url,
                    \(ReplicaRows.art("poster_url", "c.id", ":me")) AS channel_poster_url,
                    (SELECT ms.overview FROM item_shown ms WHERE ms.item_id = v.id) AS overview,
                    (SELECT ms.external_id FROM item_shown ms WHERE ms.item_id = v.id) AS external_id, m.published_at,
                    (SELECT f.duration_ms FROM item_file x JOIN media_file f ON f.id = x.media_file_id
                        WHERE x.item_id = v.id ORDER BY f.id LIMIT 1) AS dur,
                    (SELECT t.height FROM item_file x JOIN track t ON t.media_file_id = x.media_file_id
                        WHERE x.item_id = v.id AND t.kind = 'video' ORDER BY x.media_file_id, t.stream_index LIMIT 1)
                        AS height,
                    COALESCE(w.watched, 0) AS watched, COALESCE(w.position_ms, 0) AS position_ms, w.last_played_at,
                    (SELECT COUNT(*) > 0 AND COUNT(*) = COUNT(uf.missing_at) FROM item_file ux
                        JOIN media_file uf ON uf.id = ux.media_file_id WHERE ux.item_id = v.id) AS unavailable
                FROM item v JOIN item c ON c.id = v.parent_id
                    LEFT JOIN item_metadata m ON m.item_id = v.id AND m.source = 'local'
                    LEFT JOIN watch_state w ON w.item_id = v.id AND w.account_id = :me
                WHERE v.kind = 'video'
                    AND v.id IN (SELECT item_id FROM \(filter.audience.rawValue) WHERE account_id = :me)
                    AND (:channel IS NULL OR v.parent_id = :channel) AND (:id IS NULL OR v.id = :id)
                    AND (NOT :unwatched OR COALESCE(w.watched, 0) = 0)
                    AND (:q IS NULL OR instr(lower(v.parsed_title), lower(:q)) > 0)
                    AND (NOT :progress OR COALESCE(w.position_ms, 0) > 0)
                ORDER BY \(by) LIMIT :limit OFFSET :offset
                """,
            arguments: [
                "me": profile, "channel": filter.channelId, "id": filter.id, "unwatched": filter.unwatched,
                "q": filter.query, "progress": filter.inProgress, "limit": filter.limit + 1, "offset": filter.offset,
            ]
        ).map { row in
            let external = text(row["external_id"])
            return YouTubeVideo(
                id: row["id"], libraryId: row["library_id"], channelId: row["parent_id"],
                channelTitle: row["channel_title"], title: row["parsed_title"], overview: text(row["overview"]),
                durationMs: row["dur"], publishedOn: (row["published_at"] as Int64?).map(day), height: row["height"],
                watched: row["watched"], positionMs: row["position_ms"],
                lastPlayedAt: (row["last_played_at"] as Int64?).map(ReplicaRows.instant), externalId: external,
                sourceUrl: external.map { "https://www.youtube.com/watch?v=\(query($0))" },
                addedAt: ReplicaRows.instant(row["added_at"]), unavailable: (row["unavailable"] as Bool) ? true : nil,
                posterUrl: row["poster_url"], channelPosterUrl: row["channel_poster_url"])
        }
        guard rows.count > filter.limit else { return (rows, nil) }
        return (Array(rows.prefix(filter.limit)), filter.offset + filter.limit)
    }

    /// The YouTube page of a channel id (UC...) or playlist id (PL...).
    private static func channelURL(_ id: String) -> String {
        id.hasPrefix("PL")
            ? "https://www.youtube.com/playlist?list=\(query(id))" : "https://www.youtube.com/channel/\(path(id))"
    }

    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~")

    /// Go's url.QueryEscape.
    private static func query(_ text: String) -> String {
        (text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? text).replacingOccurrences(
            of: "%20", with: "+")
    }

    /// Go's url.PathEscape.
    private static func path(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: unreserved.union(CharacterSet(charactersIn: "$&+,:;=@")))
            ?? text
    }

    /// The UTC calendar day of an instant, as the API's dates read.
    private static func day(_ ms: Int64) -> String {
        Date.ISO8601FormatStyle(timeZone: .gmt).year().month().day().format(ReplicaRows.instant(ms))
    }

    /// An empty text is absent, as the server leaves it out.
    private static func text(_ value: String?) -> String? { value?.isEmpty == false ? value : nil }
}
