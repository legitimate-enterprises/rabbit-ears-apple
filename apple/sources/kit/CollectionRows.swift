import Foundation
import GRDB
import RabbitEarsAPI

/// Movie collections as the server answers them to the active profile of
/// the device's household for the same rows.
enum CollectionRows {
    /// collection.Order over collection_movie cm and item: by position while
    /// they carry one, else by release date (a bare year before full dates of
    /// that year, undated last), then sort title.
    static let order = """
        cm.position IS NULL, cm.position, \(released) IS NULL, \(released),
        \(ReplicaRows.sortTitle("item")) COLLATE NOCASE, item.id
        """
    private static let released =
        "COALESCE((SELECT md.release_date FROM item_shown md WHERE md.item_id = item.id),"
        + " CAST(item.parsed_year AS TEXT))"

    /// The collections the profile browses, by name, as listCollections:
    /// the household's own, and TMDB's holding two or more while metadata
    /// comes from TMDB; a kid sees none holding nothing it may see, nor does
    /// an adult hiding kids' content, who still sees an empty one. `holding`
    /// keeps those holding it, as getItem names them, for a movie the
    /// profile may open.
    static func list(_ db: Database, profile: UID, only: UID? = nil, holding: UID? = nil) throws -> [MovieCollection] {
        let seen =
            "(SELECT COUNT(*) FROM collection_movie cm WHERE cm.collection_id = c.id"
            + " AND \(PlaylistRows.seen("cm.item_id")))"
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT c.*, \(seen) AS movie_count,
                    c.source = 'custom' AND EXISTS (SELECT 1 FROM collection_movie o WHERE o.collection_id = c.id
                        AND o.position IS NOT NULL) AS custom_order
                FROM collection c, (SELECT browse_mode AS mode FROM profile_audience WHERE account_id = :profile) a
                WHERE (c.household_id = (SELECT household_id FROM replica_meta) OR c.source = 'tmdb'
                        AND (SELECT use_remote FROM metadata_setting)
                        AND (SELECT COUNT(*) FROM collection_movie n WHERE n.collection_id = c.id) >= 2)
                    AND (a.mode = 0 OR \(seen) > 0
                        OR a.mode = 2 AND NOT EXISTS (SELECT 1 FROM collection_movie e WHERE e.collection_id = c.id))
                    AND (:id IS NULL OR c.id = :id)
                    AND (:movie IS NULL OR EXISTS (SELECT 1 FROM collection_movie x
                            WHERE x.collection_id = c.id AND x.item_id = :movie)
                        AND EXISTS (SELECT 1 FROM profile_item_open o JOIN item om ON om.id = o.item_id
                            WHERE o.account_id = :profile AND o.item_id = :movie AND om.kind = 'movie'))
                ORDER BY c.name COLLATE NOCASE, c.id
                """, arguments: ["profile": profile, "id": only, "movie": holding])
        return rows.compactMap { collection($0, count: $0["movie_count"], customOrder: $0["custom_order"]) }
    }

    /// The collections by id, whoever may see them, counting nothing, for a
    /// playlist entry to fill in.
    static func collections(_ db: Database, ids: [UID]) throws -> [UID: MovieCollection] {
        let rows = try Row.fetchAll(
            db, sql: "SELECT * FROM collection WHERE id IN (SELECT unhex(value, '-') FROM json_each(?))",
            arguments: [ReplicaRows.json(ids)])
        return Dictionary(
            uniqueKeysWithValues: rows.compactMap { row in
                collection(row, count: 0, customOrder: false).map { ($0.id, $0) }
            })
    }

    /// The collection's movies the profile browses, in collection order, as listCollectionMovies answers.
    static func movies(_ db: Database, profile: UID, of id: UID) throws -> [Item] {
        let ids = try UID.fetchAll(
            db,
            sql: """
                SELECT item.id FROM collection_movie cm JOIN item ON item.id = cm.item_id WHERE cm.collection_id = ?
                    AND item.id IN (SELECT item_id FROM profile_item WHERE account_id = ?)
                ORDER BY \(order)
                """, arguments: [id, profile])
        let items = Dictionary(
            uniqueKeysWithValues: try ReplicaRows.items(
                db, "i.id IN (SELECT unhex(value, '-') FROM json_each(?))", [ReplicaRows.json(ids)]
            ).map { ($0.id, $0) })
        return ids.compactMap { items[$0] }
    }

    /// Every movie of the collection, seen or not, in collection order, as the server moves one among them.
    static func order(_ db: Database, of id: UID) throws -> [UID] {
        try UID.fetchAll(
            db,
            sql: """
                SELECT item.id FROM collection_movie cm JOIN item ON item.id = cm.item_id WHERE cm.collection_id = ?
                ORDER BY \(order)
                """,
            arguments: [id])
    }

    private static func collection(_ row: Row, count: Int, customOrder: Bool) -> MovieCollection? {
        guard let source = Components.Schemas.CollectionSource(rawValue: row["source"]) else { return nil }
        let overview: String? = row["overview"]
        return MovieCollection(
            id: row["id"], source: source, name: row["name"], overview: overview?.isEmpty == false ? overview : nil,
            householdId: row["household_id"], tmdbId: row["tmdb_id"], movieCount: count, customOrder: customOrder,
            createdAt: ReplicaRows.instant(row["created_at"]), modifiedAt: ReplicaRows.instant(row["modified_at"]),
            createdBy: row["created_by"], modifiedBy: row["modified_by"])
    }
}
