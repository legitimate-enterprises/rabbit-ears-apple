import Foundation
import GRDB
import RabbitEarsAPI

/// The active adult's friend writes that replay, each made in the replica
/// at once. Accepting does not replay, so it is never queued.
extension ActionQueue {
    /// A request lives 30 days from when it is sent.
    static let friendRequestLife: TimeInterval = 30 * 86400

    func sendFriendRequest(_ id: UID, to email: String, as profileId: UID) async throws {
        try await act(
            as: profileId, touching: [.row("friend_request", id)],
            call: { client, _ in _ = try await client.sendFriendRequest(body: .json(.init(id: id, email: email))) },
            apply: { db, at in
                let expires = at.addingTimeInterval(Self.friendRequestLife)
                try db.execute(
                    sql: "INSERT INTO friend_request(id, from_id, email, created_at, expires_at) "
                        + "VALUES (?, ?, ?, ?, ?)",
                    arguments: [id, profileId, email, Self.ms(at), Self.ms(expires)])
            })
    }

    /// The sender's own request goes.
    func withdrawFriendRequest(_ id: UID, as profileId: UID) async throws {
        try await act(
            as: profileId, touching: [.row("friend_request", id)],
            call: { client, _ in _ = try await client.deleteFriendRequest(path: .init(requestId: id)) },
            apply: { db, _ in try db.execute(sql: "DELETE FROM friend_request WHERE id = ?", arguments: [id]) })
    }

    /// A request to the adult is declined, which only they ever see.
    func declineFriendRequest(_ id: UID, as profileId: UID) async throws {
        try await act(
            as: profileId, touching: [.row("friend_request_decline", profileId, id)],
            call: { client, _ in _ = try await client.deleteFriendRequest(path: .init(requestId: id)) },
            apply: { db, at in
                try db.execute(
                    sql: "INSERT OR IGNORE INTO friend_request_decline(account_id, request_id, created_at) "
                        + "VALUES (?, ?, ?)",
                    arguments: [profileId, id, Self.ms(at)])
            })
    }

    /// A friendship is stored once, its ids in bytewise order.
    func deleteFriend(_ friendId: UID, as profileId: UID) async throws {
        let (low, high) = (min(profileId, friendId), max(profileId, friendId))
        try await act(
            as: profileId, touching: [.row("friendship", low, high)],
            call: { client, _ in _ = try await client.deleteFriend(path: .init(profileId: friendId)) },
            apply: { db, _ in
                try db.execute(
                    sql: "DELETE FROM friendship WHERE (a_id = ?1 AND b_id = ?2) OR (a_id = ?2 AND b_id = ?1)",
                    arguments: [low, high])
            })
    }
}
