import Foundation
import GRDB
import RabbitEarsAPI
import XCTest

@testable import RabbitEarsKit

/// Starring and unstarring leave the row the server's favorite repository
/// stores, and queue the call that replays it with the action's instant.
final class FavoriteActionsTests: ActionQueueCase {
    let now = ActionQueue.ms(ActionQueueCase.now)

    /// Dune (20) is not starred; Alpha (21) was starred a second before now
    /// and Night (22) a millisecond after it.
    private func library() throws -> Replica {
        try fixture.v1 { db in
            try db.account(1, "Avery")
            try db.item(20, "movie", "Dune")
            try db.item(21, "show", "Alpha")
            try db.item(22, "show", "Night")
            try db.execute(
                sql: "INSERT INTO favorite VALUES (?, ?, ?), (?, ?, ?)",
                arguments: [UID.n(1), UID.n(21), now - 1000, UID.n(1), UID.n(22), now + 1])
        }
    }

    private func starred(_ replica: Replica) async throws -> [UID: Int64] {
        try await replica.read { db in
            Dictionary(
                uniqueKeysWithValues: try Row.fetchAll(
                    db, sql: "SELECT item_id, created_at FROM favorite WHERE account_id = ?", arguments: [UID.n(1)]
                ).map { ($0["item_id"] as UID, $0["created_at"] as Int64) })
        }
    }

    private func actions(_ replica: Replica) async throws -> [String] {
        try await replica.read {
            try String.fetchAll(
                $0,
                sql: """
                    SELECT a.operation_id || ' ' || a.method || ' ' || a.path || ' ' || t.table_name || ' '
                        || t.key1 || '/' || t.key2
                    FROM queue.action a JOIN queue.action_touch t ON t.action = a.seq ORDER BY a.seq
                    """)
        }
    }

    private func sentPaths() -> [String] {
        batches().flatMap(\.actions).map { "\($0.method.rawValue) \($0.path)" }
    }

    func testStarringIsTheActionsInstantAndKeepsAFirstStar() async throws {
        let replica = try library()
        let queue = queue(replica)
        try await queue.putFavorite(item: 20, as: 1)
        try await queue.putFavorite(item: 21, as: 1)
        let rows = try await starred(replica)
        XCTAssertEqual(rows[20], now)
        XCTAssertEqual(rows[21], now - 1000, "a favorite keeps its first instant")
        let queued = try await actions(replica)
        XCTAssertEqual(
            queued,
            [20, 21].map { (item: Int) in
                "putFavorite PUT /profiles/\(UID.n(1))/favorites/\(UID.n(item))?at=2027-01-15T08%3A00%3A00.123Z"
                    + " favorite \(UID.n(1))/\(UID.n(item))"
            })
    }

    func testUnstarringRemovesOnlyAStarMadeNoLater() async throws {
        let replica = try library()
        let queue = queue(replica)
        try await queue.deleteFavorite(item: 21, as: 1)
        try await queue.deleteFavorite(item: 22, as: 1)
        let rows = try await starred(replica)
        XCTAssertNil(rows[21])
        XCTAssertEqual(rows[22], now + 1, "starred after the unstar")
        let queued = try await actions(replica)
        XCTAssertEqual(
            queued.first,
            "deleteFavorite DELETE /profiles/\(UID.n(1))/favorites/\(UID.n(21))?at=2027-01-15T08%3A00%3A00.123Z"
                + " favorite \(UID.n(1))/\(UID.n(21))")
    }

    func testOfflineAStarAppliesAtOnceAndIsSentOnReconnect() async throws {
        let replica = try library()
        let queue = queue(replica)
        transport.failure = URLError(.notConnectedToInternet)
        try await queue.putFavorite(item: 20, as: 1)
        try await queue.deleteFavorite(item: 21, as: 1)
        let rows = try await starred(replica)
        XCTAssertEqual(rows[20], now)
        XCTAssertNil(rows[21])
        let offline = await queue.flush()
        XCTAssertEqual(offline, .offline)
        transport.failure = nil
        let flushed = await queue.flush()
        XCTAssertEqual(flushed, .done)
        XCTAssertEqual(
            sentPaths(),
            [
                "PUT /profiles/\(UID.n(1))/favorites/\(UID.n(20))?at=2027-01-15T08%3A00%3A00.123Z",
                "DELETE /profiles/\(UID.n(1))/favorites/\(UID.n(21))?at=2027-01-15T08%3A00%3A00.123Z",
            ])
        let left = try await queued(replica)
        XCTAssertEqual(left, [])
    }
}
