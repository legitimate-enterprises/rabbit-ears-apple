import Foundation
import GRDB
import RabbitEarsAPI

/// Stars, each applied to the replica as the server's favorite repository
/// stores it and queued for replay with the action's instant.
extension ActionQueue {
    /// putFavorite: a title already starred keeps its first instant.
    func putFavorite(item: UID, as profileId: UID) async throws {
        try await act(
            as: profileId, touching: [.row("favorite", profileId, item)],
            call: { client, at in
                _ = try await client.putFavorite(path: .init(profileId: profileId, itemId: item), query: .init(at: at))
            },
            apply: { db, at in
                try db.execute(
                    sql: """
                        INSERT INTO favorite (account_id, item_id, created_at) VALUES (?, ?, ?)
                        ON CONFLICT (account_id, item_id) DO NOTHING
                        """, arguments: [profileId, item, Self.ms(at)])
            })
    }

    /// deleteFavorite: a star made later than the action stays.
    func deleteFavorite(item: UID, as profileId: UID) async throws {
        try await act(
            as: profileId, touching: [.row("favorite", profileId, item)],
            call: { client, at in
                _ = try await client.deleteFavorite(
                    path: .init(profileId: profileId, itemId: item), query: .init(at: at))
            },
            apply: { db, at in
                try db.execute(
                    sql: "DELETE FROM favorite WHERE account_id = ? AND item_id = ? AND created_at <= ?",
                    arguments: [profileId, item, Self.ms(at)])
            })
    }
}
