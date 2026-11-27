import Foundation
import GRDB
import RabbitEarsAPI

/// Watch-state writes, each applied to the replica as the server's
/// watch-state repository stores it and queued for replay. A write over a
/// state that changed later than it is dropped, as on the server.
extension ActionQueue {
    public enum WatchRefusal: Error, LocalizedError {
        /// An item the profile may not see, which the server answers as not found.
        case notFound
        /// A kind the server does not mark, which it answers as invalid.
        case notWatchable

        public var errorDescription: String? {
            switch self {
            case .notFound: "That title is no longer available."
            case .notWatchable: "Only movies, shows, seasons, episodes, channels and videos are watched."
            }
        }
    }

    /// putWatchState: marks the item, counting a play when it becomes
    /// watched, resumes at `positionMs` in `edition`, else the default one.
    public func putWatchState(
        _ watched: Bool, positionMs: Int64? = nil, edition: UID? = nil, item: UID, as profileId: UID
    ) async throws {
        try await act(
            as: profileId, touching: [try Self.watchKey(profileId, item)],
            call: { client, at in
                _ = try await client.putWatchState(
                    path: .init(profileId: profileId, itemId: item),
                    body: .json(.init(watched: watched, positionMs: positionMs, editionId: edition, at: at)))
            },
            apply: { db, at in
                try db.execute(
                    sql: """
                        INSERT INTO watch_state (account_id, item_id, position_ms, watched, play_count, last_played_at,
                            changed_at, edition_id)
                        VALUES (?1, ?2, ?3, ?4, ?4, ?5, ?5, COALESCE(?6, \(Self.defaultEdition("?2"))))
                        ON CONFLICT (account_id, item_id) DO UPDATE SET position_ms = excluded.position_ms,
                            watched = excluded.watched, play_count = play_count + (excluded.watched AND NOT watched),
                            last_played_at = excluded.last_played_at, changed_at = excluded.changed_at,
                            edition_id = excluded.edition_id
                        WHERE watch_state.changed_at <= excluded.changed_at
                        """, arguments: [profileId, item, positionMs ?? 0, watched, Self.ms(at), edition])
            })
    }

    /// putWatchStates: marks a selection with no position, a show or season
    /// as each episode of it the profile may see and a channel as each of
    /// its videos. The episodes and videos are sent themselves, in as many
    /// actions as the touched-row limit needs. Nothing is queued when the
    /// profile may not see an item or it is of a kind not watched.
    public func putWatchStates(
        _ watched: Bool, items ids: [UID], as profileId: UID, in replica: Replica
    ) async throws {
        let targets = try await replica.read { try Self.targets(of: ids, profileId, $0) }
        for start in stride(from: 0, to: targets.count, by: Self.touchedLimit) {
            let chunk = Array(targets[start..<min(start + Self.touchedLimit, targets.count)])
            try await act(
                as: profileId, touching: try chunk.map { try Self.watchKey(profileId, $0) },
                call: { client, at in
                    _ = try await client.putWatchStates(
                        path: .init(profileId: profileId), body: .json(.init(itemIds: chunk, watched: watched, at: at)))
                },
                apply: { db, at in try Self.mark(db, profileId, chunk, watched: watched, at: at) })
        }
    }

    /// watchstate.Mark(watched, 0) of each of `items`, as the server saves
    /// it: the cut kept, a play counted when it becomes watched, and a state
    /// that changed later left alone.
    static func mark(_ db: Database, _ profileId: UID, _ items: [UID], watched: Bool, at: Date) throws {
        for item in items {
            try db.execute(
                sql: """
                    INSERT INTO watch_state (account_id, item_id, position_ms, watched, play_count,
                        last_played_at, changed_at, edition_id)
                    VALUES (?1, ?2, 0, ?3, ?3, ?4, ?4, NULL)
                    ON CONFLICT (account_id, item_id) DO UPDATE SET position_ms = 0,
                        watched = excluded.watched,
                        play_count = play_count + (excluded.watched AND NOT watched),
                        last_played_at = excluded.last_played_at, changed_at = excluded.changed_at
                    WHERE watch_state.changed_at <= excluded.changed_at
                    """, arguments: [profileId, item, watched, ms(at)])
        }
    }

    /// deleteWatchState: forgets the item's state unless it changed later.
    public func deleteWatchState(item: UID, as profileId: UID) async throws {
        try await act(
            as: profileId, touching: [try Self.watchKey(profileId, item)],
            call: { client, at in
                _ = try await client.deleteWatchState(
                    path: .init(profileId: profileId, itemId: item), query: .init(at: at))
            },
            apply: { db, at in
                try db.execute(
                    sql: "DELETE FROM watch_state WHERE account_id = ? AND item_id = ? AND changed_at <= ?",
                    arguments: [profileId, item, Self.ms(at)])
            })
    }

    /// recordPlay: counts one finished play of `edition`, else the default
    /// one, that ended `at`, for a play the server did not stream. The count
    /// only adds and lastPlayedAt goes to the later play; over a state that
    /// changed no later, the item is watched from the start of that edition.
    public func recordPlay(item: UID, edition: UID?, as profileId: UID, at ended: Date) async throws {
        try await act(
            as: profileId, touching: [try Self.watchKey(profileId, item)],
            call: { client, _ in
                _ = try await client.recordPlay(
                    path: .init(profileId: profileId, itemId: item), body: .json(.init(at: ended, editionId: edition)))
            },
            apply: { db, at in
                try db.execute(
                    sql: """
                        INSERT INTO watch_state (account_id, item_id, position_ms, watched, play_count, last_played_at,
                            changed_at, edition_id)
                        VALUES (?1, ?2, 0, 1, 1, ?3, ?3, COALESCE(?4, \(Self.defaultEdition("?2"))))
                        ON CONFLICT (account_id, item_id) DO UPDATE SET
                            play_count = play_count + 1,
                            last_played_at = MAX(COALESCE(last_played_at, 0), excluded.last_played_at),
                            watched = CASE WHEN changed_at <= excluded.changed_at THEN 1 ELSE watched END,
                            position_ms = CASE WHEN changed_at <= excluded.changed_at THEN 0 ELSE position_ms END,
                            edition_id = CASE WHEN changed_at <= excluded.changed_at THEN excluded.edition_id
                                ELSE edition_id END,
                            changed_at = MAX(changed_at, excluded.changed_at)
                        """,
                    // The server takes a time ahead of its own as now.
                    arguments: [profileId, item, Self.ms(min(ended, at)), edition])
            })
    }

    /// The leaf items a putWatchStates selection marks, each once, in order.
    static func targets(of ids: [UID], _ profile: UID, _ db: Database) throws -> [UID] {
        let seen = "IN (SELECT item_id FROM profile_item_open WHERE account_id = ?2)"
        var targets: [UID] = []
        for id in ids {
            guard
                let kind = try String.fetchOne(
                    db, sql: "SELECT kind FROM item WHERE id = ?1 AND id \(seen)", arguments: [id, profile])
            else { throw WatchRefusal.notFound }
            switch kind {
            case "movie", "episode", "video":
                targets.append(id)
            case "show":
                targets += try UID.fetchAll(
                    db,
                    sql: """
                        SELECT e.id FROM item e JOIN item s ON s.id = e.parent_id
                        WHERE s.parent_id = ?1 AND e.kind = 'episode' AND e.id \(seen)
                        ORDER BY s.season_number, e.episode_number
                        """, arguments: [id, profile])
            case "season":
                targets += try UID.fetchAll(
                    db,
                    sql: """
                        SELECT i.id FROM item i WHERE i.parent_id = ?1 AND i.kind = 'episode' AND i.id \(seen)
                        ORDER BY \(ReplicaRows.titleOrder)
                        """, arguments: [id, profile])
            case "channel":
                // Every video of it, as the server marks them whoever sees them.
                targets += try UID.fetchAll(
                    db, sql: "SELECT id FROM item WHERE parent_id = ? AND kind = 'video' ORDER BY id", arguments: [id])
            default:
                throw WatchRefusal.notWatchable
            }
        }
        var marked: Set<UID> = []
        return targets.filter { marked.insert($0).inserted }
    }

    static func watchKey(_ profile: UID, _ item: UID) throws -> Components.Schemas.SyncTouched {
        try .row("watch_state", profile, item)
    }

    /// edition.DefaultOf: the item's first untagged edition with a file on
    /// disk, else the first with one, else the same among those with files;
    /// NULL when none has a file.
    static func defaultEdition(_ item: String) -> String {
        """
        (SELECT de.id FROM edition de WHERE de.item_id = \(item)
            AND EXISTS (SELECT 1 FROM edition_file def WHERE def.edition_id = de.id)
            ORDER BY NOT EXISTS (SELECT 1 FROM edition_file dp JOIN media_file dpf ON dpf.id = dp.media_file_id
                WHERE dp.edition_id = de.id AND dpf.missing_at IS NULL), de.tag IS NOT NULL, de.id LIMIT 1)
        """
    }

    /// An instant as the replica stores it, to the millisecond.
    static func ms(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded(.down)) }
}
