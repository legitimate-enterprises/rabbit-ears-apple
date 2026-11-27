import Foundation
import GRDB
import RabbitEarsAPI

/// The household's writes on rows that already exist: allow lists, kids'
/// content and profile settings, each changed in the replica at once and
/// queued as the call that changes it on the server.
extension ActionQueue {
    func allowItem(_ itemId: Int64, for kidId: Int64, as profileId: Int64) async throws {
        try await act(
            as: profileId, touching: [.init(table: "account_allow", key: Self.key(kidId, itemId))],
            call: { client, _ in _ = try await client.allowItem(path: .init(profileId: kidId, itemId: itemId)) },
            apply: { db, _ in
                try db.execute(
                    sql: "INSERT OR IGNORE INTO account_allow(account_id, item_id) VALUES (?, ?)",
                    arguments: [kidId, itemId])
            })
    }

    func disallowItem(_ itemId: Int64, for kidId: Int64, as profileId: Int64) async throws {
        try await act(
            as: profileId, touching: [.init(table: "account_allow", key: Self.key(kidId, itemId))],
            call: { client, _ in _ = try await client.disallowItem(path: .init(profileId: kidId, itemId: itemId)) },
            apply: { db, _ in
                try db.execute(
                    sql: "DELETE FROM account_allow WHERE account_id = ? AND item_id = ?", arguments: [kidId, itemId])
            })
    }

    /// Nil leaves a setting as it is. `account_card` mirrors the color.
    func setProfilePreferences(
        _ id: Int64, color: String?, hideKidsContent: Bool?, autoplay: Bool?, as profileId: Int64
    ) async throws {
        var touched = [Components.Schemas.SyncTouched(table: "account", key: try Self.key(id))]
        if color != nil { touched.append(.init(table: "account_card", key: try Self.key(id))) }
        try await act(
            as: profileId, touching: touched,
            call: { client, _ in
                _ = try await client.setProfilePreferences(
                    path: .init(profileId: id),
                    body: .json(.init(color: color, hideKidsContent: hideKidsContent, autoplay: autoplay)))
            },
            apply: { db, _ in
                try db.execute(
                    sql: """
                        UPDATE account SET color = COALESCE(?, color),
                            hide_kids_content = COALESCE(?, hide_kids_content), no_autoplay = COALESCE(?, no_autoplay)
                        WHERE id = ?
                        """, arguments: [color, hideKidsContent, autoplay.map { !$0 }, id])
                guard let color else { return }
                try db.execute(sql: "UPDATE account_card SET color = ? WHERE id = ?", arguments: [color, id])
            })
    }

    /// A movie's or show's own override, nil to leave it to the rating;
    /// its seasons and episodes follow it through the replica's views.
    public func setKidsContent(_ kidsContent: Bool?, for itemId: Int64, as profileId: Int64) async throws {
        try await act(
            as: profileId, touching: [.init(table: "item", key: Self.key(itemId))],
            call: { client, _ in
                if let kidsContent {
                    _ = try await client.setKidsContent(
                        path: .init(itemId: itemId), body: .json(.init(kidsContent: kidsContent)))
                } else {
                    _ = try await client.clearKidsContent(path: .init(itemId: itemId))
                }
            },
            apply: { db, _ in try Self.setKids(kidsContent, [itemId], db) })
    }

    /// Movies, shows and channels, one action per batch of touched rows the server takes.
    public func setKidsContents(_ kidsContent: Bool, for itemIds: [Int64], as profileId: Int64) async throws {
        for start in stride(from: 0, to: itemIds.count, by: Self.touchedLimit) {
            let ids = Array(itemIds[start..<min(start + Self.touchedLimit, itemIds.count)])
            try await act(
                as: profileId, touching: try ids.map { .init(table: "item", key: try Self.key($0)) },
                call: { client, _ in
                    _ = try await client.setKidsContents(body: .json(.init(itemIds: ids, kidsContent: kidsContent)))
                },
                apply: { db, _ in try Self.setKids(kidsContent, ids, db) })
        }
    }

    public func setYouTubeChannelForKids(_ forKids: Bool, channel id: Int64, as profileId: Int64) async throws {
        try await act(
            as: profileId, touching: [.init(table: "item", key: Self.key(id))],
            call: { client, _ in
                _ = try await client.setYouTubeChannelForKids(
                    path: .init(channelId: id), body: .json(.init(forKids: forKids)))
            },
            apply: { db, _ in try Self.setKids(forKids, [id], db) })
    }

    private static func setKids(_ value: Bool?, _ ids: [Int64], _ db: Database) throws {
        try db.execute(literal: "UPDATE item SET kids_content = \(value) WHERE id IN \(ids)")
    }

    private static func key(_ parts: Int64...) throws -> [Components.Schemas.SyncScalar] {
        try parts.map { try .init(unvalidatedValue: Int($0)) }
    }
}
