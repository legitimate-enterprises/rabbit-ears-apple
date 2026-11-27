import Foundation
import GRDB
import RabbitEarsAPI

/// The playlist writes this device makes. A create carries its client ids,
/// and `apply` writes the rows and audit cells the server will.
extension ActionQueue {
    /// The profile's new playlist under the client id `id`.
    func createPlaylist(as profile: UID, _ id: UID, name: String, kind: PlaylistKind) async throws {
        try await act(
            as: profile, touching: [try .row("playlist", id)],
            call: { client, _ in
                _ = try await client.createPlaylist(
                    path: .init(profileId: profile), body: .json(.init(id: id, name: name, kind: kind)))
            },
            apply: { db, at in
                try db.execute(
                    sql: """
                        INSERT INTO playlist(id, account_id, name, kind, station_owned, created_at, modified_at,
                            created_by, modified_by)
                        VALUES (?1, ?2, ?3, ?4, 0, ?5, ?5, ?2, ?2)
                        """, arguments: [id, profile, name, kind.rawValue, Self.ms(at)])
            })
    }

    /// One entry, named in `entry` with its client id, rank and edition exactly as the server is to write it.
    func addEntry(as profile: UID, to playlist: UID, _ entry: PlaylistEntryInput) async throws {
        try await act(
            as: profile, touching: try Self.touched([entry]),
            call: { client, _ in
                _ = try await client.addPlaylistEntry(
                    path: .init(profileId: profile, playlistId: playlist), body: .json(entry))
            },
            apply: { db, at in try Self.insert(db, [entry], in: playlist, by: profile, at) })
    }

    /// Entries appended in consecutive calls of at most `itemsLimit`, as
    /// addEntry names each; the server ranks each call's itself, after its
    /// last entry, as `entries` already are.
    func addEntries(as profile: UID, to playlist: UID, _ entries: [PlaylistEntryInput]) async throws {
        for start in stride(from: 0, to: entries.count, by: Self.itemsLimit) {
            try await addBatch(
                as: profile, to: playlist, Array(entries[start..<min(start + Self.itemsLimit, entries.count)]))
        }
    }

    private func addBatch(as profile: UID, to playlist: UID, _ entries: [PlaylistEntryInput]) async throws {
        let sent = entries.map { entry in
            var entry = entry
            entry.rank = nil
            return entry
        }
        try await act(
            as: profile, touching: try Self.touched(entries),
            call: { client, _ in
                _ = try await client.addPlaylistEntries(
                    path: .init(profileId: profile, playlistId: playlist), body: .json(.init(entries: sent)))
            },
            apply: { db, at in try Self.insert(db, entries, in: playlist, by: profile, at) })
    }

    private static func touched(_ entries: [PlaylistEntryInput]) throws -> [Components.Schemas.SyncTouched] {
        try entries.compactMap(\.id).map { try .row("playlist_entry", $0) }
    }

    private static func insert(
        _ db: Database, _ entries: [PlaylistEntryInput], in playlist: UID, by profile: UID, _ at: Date
    ) throws {
        for entry in entries {
            try db.execute(
                sql: """
                    INSERT INTO playlist_entry(id, playlist_id, item_id, collection_id, edition_id, rank, added_at,
                        created_at, modified_at, created_by, modified_by)
                    VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?7, ?7, ?8, ?8)
                    """,
                arguments: [
                    entry.id, playlist, entry.itemId, entry.collectionId, entry.editionId, entry.rank, ms(at), profile,
                ])
        }
    }

    func renamePlaylist(as profile: UID, _ id: UID, name: String, kind: PlaylistKind) async throws {
        try await act(
            as: profile, touching: [try .row("playlist", id)],
            call: { client, _ in
                _ = try await client.replacePlaylist(
                    path: .init(profileId: profile, playlistId: id), body: .json(.init(name: name, kind: kind)))
            },
            apply: { db, at in
                try db.execute(
                    sql: "UPDATE playlist SET name = ?, kind = ?, modified_at = ?, modified_by = ? WHERE id = ?",
                    arguments: [name, kind.rawValue, Self.ms(at), profile, id])
            })
    }

    /// Refused at once while one of the owner's stations plays it, as the
    /// server refuses. Its entries, shares and cover stay until the server's
    /// tombstones arrive: nothing reads them without their playlist, and a
    /// rejection restores the playlist with them.
    func deletePlaylist(as profile: UID, _ id: UID) async throws {
        try await act(
            as: profile, touching: [try .row("playlist", id)],
            call: { client, _ in
                _ = try await client.deletePlaylist(path: .init(profileId: profile, playlistId: id))
            },
            apply: { db, _ in
                let played =
                    try Bool.fetchOne(
                        db,
                        sql: "SELECT EXISTS (SELECT 1 FROM station s JOIN playlist p ON p.id = s.playlist_id"
                            + " WHERE p.id = ? AND s.account_id = p.account_id)", arguments: [id]) ?? false
                guard !played else {
                    throw AppError.server(
                        "A station plays this playlist. Delete the station or give it another playlist first.")
                }
                try db.execute(sql: "DELETE FROM playlist WHERE id = ?", arguments: [id])
            })
    }

    /// Gives the entry `rank`, which places it among the others.
    func rankEntry(as profile: UID, _ entry: PlaylistEntry, rank: String) async throws {
        try await act(
            as: profile, touching: [try .row("playlist_entry", entry.id)],
            call: { client, _ in
                _ = try await client.replacePlaylistEntry(
                    path: .init(profileId: profile, playlistId: entry.playlistId, entryId: entry.id),
                    body: .json(.init(itemId: entry.itemId, collectionId: entry.collectionId, rank: rank)))
            },
            apply: { db, at in
                try db.execute(
                    sql: "UPDATE playlist_entry SET rank = ?, modified_at = ?, modified_by = ? WHERE id = ?",
                    arguments: [rank, Self.ms(at), profile, entry.id])
            })
    }

    func removeEntry(as profile: UID, _ entry: PlaylistEntry) async throws {
        try await act(
            as: profile, touching: [try .row("playlist_entry", entry.id)],
            call: { client, _ in
                _ = try await client.removePlaylistEntry(
                    path: .init(profileId: profile, playlistId: entry.playlistId, entryId: entry.id))
            },
            apply: { db, _ in try db.execute(sql: "DELETE FROM playlist_entry WHERE id = ?", arguments: [entry.id]) })
    }

    /// Creates, replaces or deletes the playlist's share with a profile, as `from` and `to` differ; nil is none.
    func share(
        as profile: UID, _ playlist: UID, with account: UID, from: PlaylistShareAccess?, to: PlaylistShareAccess?
    ) async throws {
        try await act(
            as: profile, touching: [try .row("playlist_share", playlist, account)],
            call: { client, _ in
                switch (from, to) {
                case (nil, let access?):
                    _ = try await client.createPlaylistShare(
                        path: .init(profileId: profile, playlistId: playlist),
                        body: .json(.init(profileId: account, access: access)))
                case (_?, let access?):
                    _ = try await client.replacePlaylistShare(
                        path: .init(profileId: profile, playlistId: playlist, shareProfileId: account),
                        body: .json(.init(access: access)))
                case (_?, nil):
                    _ = try await client.deletePlaylistShare(
                        path: .init(profileId: profile, playlistId: playlist, shareProfileId: account))
                case (nil, nil): break
                }
            },
            apply: { db, at in
                try Self.share(db, ("playlist_share", "account_id"), (playlist, account), to, at)
            })
    }

    /// share(as:_:with:from:to:) for everyone in a household.
    func share(
        as profile: UID, _ playlist: UID, withHousehold household: UID, from: PlaylistShareAccess?,
        to: PlaylistShareAccess?
    ) async throws {
        try await act(
            as: profile, touching: [try .row("playlist_household_share", playlist, household)],
            call: { client, _ in
                switch (from, to) {
                case (nil, let access?):
                    _ = try await client.createPlaylistHouseholdShare(
                        path: .init(profileId: profile, playlistId: playlist),
                        body: .json(.init(householdId: household, access: access)))
                case (_?, let access?):
                    _ = try await client.replacePlaylistHouseholdShare(
                        path: .init(profileId: profile, playlistId: playlist, householdId: household),
                        body: .json(.init(access: access)))
                case (_?, nil):
                    _ = try await client.deletePlaylistHouseholdShare(
                        path: .init(profileId: profile, playlistId: playlist, householdId: household))
                case (nil, nil): break
                }
            },
            apply: { db, at in
                try Self.share(db, ("playlist_household_share", "household_id"), (playlist, household), to, at)
            })
    }

    /// `share` names the table and the column of whom it reaches.
    private static func share(
        _ db: Database, _ share: (table: String, column: String), _ key: (playlist: UID, whom: UID),
        _ access: PlaylistShareAccess?, _ at: Date
    ) throws {
        guard let access else {
            try db.execute(
                sql: "DELETE FROM \(share.table) WHERE playlist_id = ? AND \(share.column) = ?",
                arguments: [key.playlist, key.whom])
            return
        }
        try db.execute(
            sql: """
                INSERT INTO \(share.table)(playlist_id, \(share.column), access, created_at) VALUES (?, ?, ?, ?)
                ON CONFLICT DO UPDATE SET access = excluded.access
                """, arguments: [key.playlist, key.whom, access.rawValue, ms(at)])
    }
}

extension PlaylistRows {
    /// A rank for position `at` among the playlist's entries other than
    /// `except`, as the server's rankAt: past the end is last, and no key
    /// sorts between two equal ranks, so a place between them lands after both.
    static func rank(_ db: Database, playlist: UID, except: UID?, at position: Int) throws -> String {
        let ranks = try String.fetchAll(
            db, sql: "SELECT rank FROM playlist_entry WHERE playlist_id = ? AND id IS NOT ? ORDER BY rank, id",
            arguments: [playlist, except])
        let at = min(max(0, position), ranks.count)
        let lower = at > 0 ? ranks[at - 1] : nil
        return try FractionalIndex.key(between: lower, and: ranks[at...].first { $0 != lower })
    }
}
