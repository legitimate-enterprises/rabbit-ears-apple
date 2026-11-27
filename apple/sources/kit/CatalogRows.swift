import Foundation
import GRDB
import RabbitEarsAPI

/// The server's catalog orders and neighbor rules over the replica, as
/// item.Repo, collection.Repo and youtube.Repo write them.
extension ReplicaRows {
    /// A profile may see an item the way the server's AudienceFor decides,
    /// which Hide kids' content does not narrow.
    static let seenBy = "IN (SELECT item_id FROM profile_item_open WHERE account_id = ?)"
    /// A profile browses an item the way the server's BrowseAudienceFor decides.
    static let browsedBy = "IN (SELECT item_id FROM profile_item WHERE account_id = ?)"

    /// listItems' order over `item i`.
    static let titleOrder = "i.parsed_title COLLATE NOCASE, i.season_number, i.episode_number, i.id"

    /// Every file of the item `id` is marked missing.
    static func unavailable(_ id: String) -> String {
        """
        (SELECT COUNT(*) > 0 AND COUNT(*) = COUNT(uf.missing_at) FROM item_file ux
            JOIN media_file uf ON uf.id = ux.media_file_id WHERE ux.item_id = \(id))
        """
    }

    /// A movie's TMDB collection while the metadata settings use remote data, as collection.franchise.
    static let franchise = """
        FROM collection_movie cm JOIN item ON item.id = cm.item_id
        WHERE cm.collection_id = (SELECT x.collection_id FROM collection_movie x
            JOIN collection xc ON xc.id = x.collection_id
            WHERE x.item_id = ?1 AND xc.source = 'tmdb' AND (SELECT use_remote FROM metadata_setting))
        """

    /// collection.Order: by position while they carry one, else release date, a bare year
    /// before the full dates of that year and undated last, then title.
    static let collectionOrder: String = {
        let date =
            "COALESCE((SELECT md.release_date FROM item_shown md WHERE md.item_id = item.id),"
            + " CAST(item.parsed_year AS TEXT))"
        let title = "COALESCE((SELECT md.title FROM item_shown md WHERE md.item_id = item.id), item.parsed_title)"
        return "cm.position IS NULL, cm.position, \(date) IS NULL, \(date), \(title) COLLATE NOCASE, item.id"
    }()

    /// An episode's show's episodes, as item.episodes.
    static let showEpisodes = """
        FROM item JOIN item se ON se.id = item.parent_id WHERE +item.kind = 'episode'
            AND se.parent_id = (SELECT ps.parent_id FROM item pe JOIN item ps ON ps.id = pe.parent_id WHERE pe.id = ?1)
        """
    /// Seasons by number with specials (0 or none) last, then episodes by number.
    static let episodeOrder = "COALESCE(se.season_number, 0) = 0, se.season_number, se.id, item.episode_number, item.id"

    /// A video's channel's videos, oldest first, as youtube.NextVideo.
    static let channelVideos = """
        FROM item LEFT JOIN item_metadata m ON m.item_id = item.id AND m.source = 'local'
        WHERE +item.kind = 'video' AND item.parent_id = (SELECT pv.parent_id FROM item pv WHERE pv.id = ?1)
        """
    static let videoOrder = "m.published_at IS NULL, m.published_at, item.added_at, item.id"

    /// item.Repo.Neighbors: the nearest item on each side of `id` among
    /// `from`, a FROM clause aliasing the candidates `item` and ending in its
    /// WHERE, that the profile browses; nil for none.
    static func neighbors(
        _ db: Database, from: String, order: String, of id: UID, browsedBy profile: UID
    ) throws -> (previous: UID?, next: UID?) {
        let row = try Row.fetchOne(
            db,
            sql: """
                WITH o AS (SELECT item.id, LAG(item.id) OVER w AS prev, LEAD(item.id) OVER w AS next \(from)
                    AND (item.id = ?1 OR item.id IN (SELECT item_id FROM profile_item WHERE account_id = ?2))
                    WINDOW w AS (ORDER BY \(order)))
                SELECT prev, next FROM o WHERE id = ?1
                """, arguments: [id, profile])
        return (row.flatMap { $0["prev"] as UID? }, row.flatMap { $0["next"] as UID? })
    }

    /// item.Repo.Next: the first item after `id` among `from` that the
    /// profile may see and that has a file on disk; nil for none.
    static func next(
        _ db: Database, from: String, order: String, after id: UID, seenBy profile: UID
    ) throws -> UID? {
        try UID.fetchOne(
            db,
            sql: """
                WITH o AS (SELECT item.id, ROW_NUMBER() OVER (ORDER BY \(order)) AS pos \(from)
                    AND (item.id = ?1 OR item.id IN (SELECT item_id FROM profile_item_open WHERE account_id = ?2)
                        AND NOT \(unavailable("item.id"))))
                SELECT id FROM o WHERE pos > (SELECT pos FROM o WHERE id = ?1) ORDER BY pos LIMIT 1
                """, arguments: [id, profile])
    }

    /// Catalog items in the order of `ids`, each once.
    static func items(_ db: Database, ids: [UID]) throws -> [Item] {
        let found = Dictionary(
            try items(db, "i.id IN (SELECT unhex(value, '-') FROM json_each(?))", [json(ids)]).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first })
        return ids.compactMap { found[$0] }
    }

    /// A collection as the server answers it to the profile `browsing`,
    /// over `collection c`.
    static let collectionSQL = """
        SELECT c.id, c.source, c.household_id, c.tmdb_id, c.name, c.overview, c.created_at, c.modified_at,
            c.created_by, c.modified_by,
            (SELECT COUNT(*) FROM collection_movie cm WHERE cm.collection_id = c.id
                AND cm.item_id IN (SELECT item_id FROM profile_item WHERE account_id = a.account_id)) AS movie_count,
            c.source = 'custom' AND EXISTS (SELECT 1 FROM collection_movie o WHERE o.collection_id = c.id
                AND o.position IS NOT NULL) AS custom_order
        FROM collection c JOIN profile_audience a ON a.account_id = ?
        """

    static func collection(_ row: Row) -> Components.Schemas.Collection? {
        guard let source = Components.Schemas.CollectionSource(rawValue: row["source"]) else { return nil }
        let overview: String? = row["overview"]
        let (created, modified): (Int64, Int64) = (row["created_at"], row["modified_at"])
        let (household, tmdb): (UID?, Int64?) = (row["household_id"], row["tmdb_id"])
        let (count, custom): (Int, Bool) = (row["movie_count"], row["custom_order"])
        return .init(
            id: row["id"], source: source, name: row["name"], overview: overview?.isEmpty == false ? overview : nil,
            householdId: household, tmdbId: tmdb, movieCount: count, customOrder: custom, createdAt: instant(created),
            modifiedAt: instant(modified), createdBy: row["created_by"], modifiedBy: row["modified_by"])
    }
}
