import Foundation
import GRDB
import RabbitEarsAPI

/// The playlist writes this device makes on rows the server already has.
extension ActionQueue {
    func renamePlaylist(as profile: Int64, _ id: Int64, name: String, kind: PlaylistKind) async throws {
        try await act(
            as: profile, touching: [try .row("playlist", id)],
            call: { client, _ in
                _ = try await client.replacePlaylist(
                    path: .init(profileId: profile, playlistId: id), body: .json(.init(name: name, kind: kind)))
            },
            apply: { db, at in
                try db.execute(
                    sql: "UPDATE playlist SET name = ?, kind = ?, updated_at = ? WHERE id = ?",
                    arguments: [name, kind.rawValue, Self.ms(at), id])
            })
    }

    /// Refused at once while one of the owner's stations plays it, as the
    /// server refuses. Its entries, shares and cover stay until the server's
    /// tombstones arrive: nothing reads them without their playlist, and a
    /// rejection restores the playlist with them.
    func deletePlaylist(as profile: Int64, _ id: Int64) async throws {
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
    func rankEntry(as profile: Int64, _ entry: PlaylistEntry, rank: String) async throws {
        try await act(
            as: profile, touching: [try .row("playlist_entry", entry.id)],
            call: { client, _ in
                _ = try await client.replacePlaylistEntry(
                    path: .init(profileId: profile, playlistId: entry.playlistId, entryId: entry.id),
                    body: .json(.init(itemId: entry.itemId, collectionId: entry.collectionId, rank: rank)))
            },
            apply: { db, _ in
                try db.execute(sql: "UPDATE playlist_entry SET rank = ? WHERE id = ?", arguments: [rank, entry.id])
            })
    }

    func removeEntry(as profile: Int64, _ entry: PlaylistEntry) async throws {
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
        as profile: Int64, _ playlist: Int64, with account: Int64, from: PlaylistShareAccess?, to: PlaylistShareAccess?
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
        as profile: Int64, _ playlist: Int64, withHousehold household: Int64, from: PlaylistShareAccess?,
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
        _ db: Database, _ share: (table: String, column: String), _ key: (playlist: Int64, whom: Int64),
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

extension Components.Schemas.SyncTouched {
    /// A replica row by its integer key parts, in primary-key order.
    static func row(_ table: String, _ key: Int64...) throws -> Self {
        .init(table: table, key: try key.map { try .init(unvalidatedValue: Int($0)) })
    }
}

extension PlaylistRows {
    /// A rank for position `at` among the playlist's entries other than
    /// `except`, as the server's rankAt: past the end is last, and no key
    /// sorts between two equal ranks, so a place between them lands after both.
    static func rank(_ db: Database, playlist: Int64, except: Int64, at position: Int) throws -> String {
        let ranks = try String.fetchAll(
            db, sql: "SELECT rank FROM playlist_entry WHERE playlist_id = ? AND id != ? ORDER BY rank, id",
            arguments: [playlist, except])
        let at = min(max(0, position), ranks.count)
        let lower = at > 0 ? ranks[at - 1] : nil
        return try FractionalIndex.key(between: lower, and: ranks[at...].first { $0 != lower })
    }
}
