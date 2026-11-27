import Foundation
import GRDB
import RabbitEarsAPI

/// Playlists, their entries and play order as the server answers them to
/// the active profile for the same rows. Totals count only the play
/// order's rows the profile may see, as playlist.Repo's visible clause does.
enum PlaylistRows {
    /// Whether the item in `column` is one the profile bound at :profile may see.
    static func seen(_ column: String) -> String {
        "\(column) IN (SELECT item_id FROM profile_item WHERE account_id = :profile)"
    }

    private static let seenRows = "FROM playlist_row r WHERE r.playlist_id = p.id AND \(seen("r.item_id"))"

    /// The profile's own playlists and those reaching it, by name, as
    /// listPlaylists answers; a station's own is left out.
    static func playlists(_ db: Database, profile: UID) throws -> [Playlist] {
        try playlists(
            db, profile: profile,
            where: "(p.account_id = :profile"
                + " OR p.id IN (SELECT playlist_id FROM playlist_reach WHERE account_id = :profile))"
                + " AND NOT p.station_owned")
    }

    /// One playlist the profile owns or that reaches it, as getPlaylist answers; nil when neither.
    static func playlist(_ db: Database, profile: UID, id: UID) throws -> Playlist? {
        try playlists(
            db, profile: profile, id: id,
            where: "p.id = :id AND (p.account_id = :profile"
                + " OR p.id IN (SELECT playlist_id FROM playlist_reach WHERE account_id = :profile))"
        ).first
    }

    private static func playlists(
        _ db: Database, profile: UID, id: UID? = nil, where condition: String
    ) throws -> [Playlist] {
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT p.id, p.account_id, p.name, p.kind, p.last_played_at, p.created_at, p.modified_at, p.created_by,
                    p.modified_by,
                    CASE WHEN p.account_id = :profile THEN 'owner'
                        WHEN (SELECT MAX(ra.access = 'write') FROM playlist_reach ra
                            WHERE ra.playlist_id = p.id AND ra.account_id = :profile)
                            AND (SELECT kind FROM account WHERE id = :profile) <> 'kid' THEN 'write'
                        ELSE 'read' END AS access,
                    EXISTS (SELECT 1 FROM playlist_share s WHERE s.playlist_id = p.id)
                        OR EXISTS (SELECT 1 FROM playlist_household_share s WHERE s.playlist_id = p.id) AS any_share,
                    (SELECT COUNT(*) \(seenRows)) AS item_count,
                    (SELECT COALESCE(SUM(r.runtime_ms), 0) \(seenRows)) AS duration_ms,
                    (SELECT a FROM (SELECT f.rank, f.id,
                        COALESCE(CASE WHEN \(seen("f.item_id")) THEN f.item_id END,
                            (SELECT item.id FROM collection_movie cm JOIN item ON item.id = cm.item_id
                                WHERE cm.collection_id = f.collection_id AND \(seen("item.id"))
                                ORDER BY \(CollectionRows.order) LIMIT 1)) AS a
                        FROM playlist_entry f WHERE f.playlist_id = p.id) WHERE a IS NOT NULL ORDER BY rank, id LIMIT 1)
                        AS art_item_id,
                    (SELECT c.id FROM cover c WHERE c.playlist_id = p.id AND (c.item_id IS NULL
                        OR EXISTS (SELECT 1 FROM playlist_entry ce
                                WHERE ce.playlist_id = p.id AND ce.item_id = c.item_id)
                            AND \(seen("c.item_id")))) AS cover_id,
                    (SELECT o.name FROM account_card o WHERE o.id = p.account_id) AS owner_name
                FROM playlist p WHERE \(condition)
                ORDER BY p.name COLLATE NOCASE, p.id
                """, arguments: ["profile": profile, "id": id])
        return rows.compactMap { row in
            guard let kind = PlaylistKind(rawValue: row["kind"]),
                let access = Components.Schemas.PlaylistAccess(rawValue: row["access"])
            else { return nil }
            let owned = access == .owner
            let id: UID = row["id"]
            return Playlist(
                id: id, profileId: row["account_id"], name: row["name"], access: access,
                shared: !owned || row["any_share"], ownerName: owned ? nil : row["owner_name"], kind: kind,
                itemCount: row["item_count"], durationMs: row["duration_ms"], artItemId: row["art_item_id"],
                lastPlayedAt: (row["last_played_at"] as Int64?).map(ReplicaRows.instant),
                imageUrl: (row["cover_id"] as UID?).map { "/api/v2/profiles/\(profile)/playlists/\(id)/image?v=\($0)" },
                createdAt: ReplicaRows.instant(row["created_at"]), modifiedAt: ReplicaRows.instant(row["modified_at"]),
                createdBy: row["created_by"], modifiedBy: row["modified_by"])
        }
    }

    /// The playlist's entries in rank order, as listPlaylistEntries answers:
    /// positions count every entry, and a kid, or an adult hiding kids'
    /// content, gets only those standing for a row it may see.
    static func entries(_ db: Database, profile: UID, playlist: UID) throws -> [PlaylistEntry] {
        let totals = Dictionary(
            uniqueKeysWithValues: try Row.fetchAll(
                db,
                sql: """
                    SELECT r.entry_id, COUNT(*) AS n, COALESCE(SUM(r.runtime_ms), 0) AS ms FROM playlist_row r
                    WHERE r.playlist_id = :playlist AND \(seen("r.item_id"))
                    GROUP BY r.entry_id
                    """, arguments: ["playlist": playlist, "profile": profile]
            ).map { ($0["entry_id"] as UID, (count: $0["n"] as Int, ms: $0["ms"] as Int64)) })
        let narrowed =
            try Int.fetchOne(
                db, sql: "SELECT browse_mode FROM profile_audience WHERE account_id = ?", arguments: [profile])
            != 0
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT e.id, e.playlist_id, e.item_id, e.collection_id, e.edition_id, e.rank, e.added_at, e.created_at,
                    e.modified_at, e.created_by, e.modified_by, i.kind,
                    ROW_NUMBER() OVER (ORDER BY e.rank, e.id) - 1 AS position
                FROM playlist_entry e LEFT JOIN item i ON i.id = e.item_id WHERE e.playlist_id = ? ORDER BY e.rank, e.id
                """, arguments: [playlist]
        ).filter { !narrowed || totals[$0["id"]] != nil }
        let itemIds = rows.compactMap { $0["item_id"] as UID? }
        let items = try catalogItems(db, itemIds)
        let songs = try songs(db, itemIds)
        let albums = try albums(db, itemIds)
        let artists = try artists(db, itemIds)
        let collections = try CollectionRows.collections(
            db, ids: rows.compactMap { $0["collection_id"] as UID? })
        return try rows.compactMap { row -> PlaylistEntry? in
            let id: UID = row["id"]
            let total = totals[id] ?? (0, 0)
            var entry = PlaylistEntry(
                id: id, playlistId: row["playlist_id"], position: row["position"], rank: row["rank"], kind: .movie,
                itemCount: total.count, durationMs: total.ms, addedAt: ReplicaRows.instant(row["added_at"]),
                createdAt: ReplicaRows.instant(row["created_at"]), modifiedAt: ReplicaRows.instant(row["modified_at"]),
                createdBy: row["created_by"], modifiedBy: row["modified_by"])
            if let collectionId: UID = row["collection_id"] {
                // One the replica lacks is gone, and the server's cascade takes its entries.
                guard var collection = collections[collectionId] else { return nil }
                collection.movieCount = total.count
                collection.customOrder = false
                (entry.kind, entry.collectionId, entry.collection) = (.collection, collectionId, collection)
                return entry
            }
            guard let itemId: UID = row["item_id"],
                let kind = (row["kind"] as String?).flatMap(Components.Schemas.PlaylistEntryKind.init)
            else { return nil }
            (entry.itemId, entry.kind) = (itemId, kind)
            if let edition: UID = row["edition_id"] {
                entry.editionId = edition
                entry.editionName = try Editions.name(of: edition, item: itemId, db)
            }
            switch kind {
            case .song: entry.song = songs[itemId]
            case .album: entry.album = albums[itemId]
            case .artist: entry.artist = artists[itemId]
            default: (entry.item, entry.show) = (items[itemId]?.item, items[itemId]?.show)
            }
            return entry
        }
    }

    /// What playing the playlist plays to the profile, as listPlaylistPlayOrder answers.
    static func playOrder(_ db: Database, profile: UID, playlist: UID) throws -> [PlayOrderRow] {
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT r.entry_id, r.item_id, i.kind, r.edition_id, r.runtime_ms FROM playlist_row r
                JOIN item i ON i.id = r.item_id
                WHERE r.playlist_id = :playlist AND \(seen("r.item_id"))
                ORDER BY r.seq
                """, arguments: ["playlist": playlist, "profile": profile])
        let ids = rows.map { $0["item_id"] as UID }
        let songs = try songs(db, ids)
        let items = try catalogItems(db, ids)
        var names: [UID: String?] = [:]
        return try rows.compactMap { row -> PlayOrderRow? in
            let itemId: UID = row["item_id"]
            guard let kind = Components.Schemas.PlaylistEntryKind(rawValue: row["kind"]) else { return nil }
            var out = PlayOrderRow(entryId: row["entry_id"], itemId: itemId, kind: kind, durationMs: row["runtime_ms"])
            if let edition: UID = row["edition_id"] {
                if names[edition] == nil { names[edition] = try Editions.name(of: edition, item: itemId, db) }
                (out.editionId, out.editionName) = (edition, names[edition] ?? nil)
            }
            if let song = songs[itemId] {
                (out.song, out.durationMs) = (song, song.durationMs)
            } else {
                (out.item, out.show) = (items[itemId]?.item, items[itemId]?.show)
            }
            return out
        }
    }

    /// Movies, shows, seasons and episodes by id, each with the show above a season or episode.
    private static func catalogItems(_ db: Database, _ ids: [UID]) throws -> [UID: (item: Item, show: Item?)] {
        let shows = Dictionary(
            uniqueKeysWithValues: try Row.fetchAll(
                db,
                sql: """
                    SELECT i.id,
                        COALESCE((SELECT p.parent_id FROM item p WHERE p.id = i.parent_id AND p.kind = 'season'),
                            i.parent_id) AS show_id
                    FROM item i WHERE i.kind IN ('season', 'episode')
                        AND i.id IN (SELECT unhex(value, '-') FROM json_each(?))
                    """, arguments: [ReplicaRows.json(ids)]
            ).compactMap { row in (row["show_id"] as UID?).map { (row["id"] as UID, $0) } })
        let all = try ReplicaRows.items(
            db, "i.id IN (SELECT unhex(value, '-') FROM json_each(?))", [ReplicaRows.json(ids + shows.values)])
        let items = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return items.mapValues { item in (item, shows[item.id].flatMap { items[$0] }) }
    }

    /// Songs by id, as the server's music views read them with nothing left out.
    static func songs(_ db: Database, _ ids: [UID]) throws -> [UID: MusicSong] {
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT \(MusicRows.songColumns)
                FROM music_song m JOIN item s ON s.id = m.item_id
                WHERE m.item_id IN (SELECT unhex(value, '-') FROM json_each(?))
                """, arguments: [ReplicaRows.json(ids)])
        return Dictionary(uniqueKeysWithValues: rows.map { ($0["id"], MusicRows.song($0)) })
    }

    /// Albums by id, counting every song. shortcut: lastPlayedAt stays nil,
    /// as the server reads it from playback sessions the replica lacks.
    static func albums(_ db: Database, _ ids: [UID]) throws -> [UID: MusicAlbum] {
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT al.id, al.library_id, al.parent_id, al.parsed_title, al.parsed_year, al.added_at, ma.artist_name,
                    ma.song_count, ma.duration_ms, ma.lossless
                FROM music_album ma JOIN item al ON al.id = ma.item_id
                WHERE ma.item_id IN (SELECT unhex(value, '-') FROM json_each(?))
                """, arguments: [ReplicaRows.json(ids)])
        let extras = try MusicRows.extras(db, rows)
        return Dictionary(uniqueKeysWithValues: rows.map { ($0["id"], MusicRows.album($0, extras[$0["id"]])) })
    }

    /// Artists by id, counting every album and song.
    static func artists(_ db: Database, _ ids: [UID]) throws -> [UID: MusicArtist] {
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT a.id, a.library_id, a.parsed_title, a.sort_title, a.added_at, mr.album_count, mr.song_count
                FROM music_artist mr JOIN item a ON a.id = mr.item_id
                WHERE mr.item_id IN (SELECT unhex(value, '-') FROM json_each(?))
                """, arguments: [ReplicaRows.json(ids)])
        let extras = try MusicRows.extras(db, rows)
        return Dictionary(uniqueKeysWithValues: rows.map { ($0["id"], MusicRows.artist($0, extras[$0["id"]])) })
    }
}
