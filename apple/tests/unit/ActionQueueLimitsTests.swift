import Foundation
import GRDB
import RabbitEarsAPI
import XCTest

@testable import RabbitEarsKit

/// Actions over what one queued action may touch, and batches over the request body limit.
final class ActionQueueLimitsTests: ActionQueueCase {
    func testAnActionTouchingMoreRowsThanTheSpecAllowsIsSentAtOnceAfterTheQueue() async throws {
        let replica = try replica()
        let queue = queue(replica)
        try await watch(queue, item: 40)
        try await mark(queue, ActionQueue.touchedLimit)
        transport.routes["PUT /profiles/\(UID.n(1))/watch-state/batch"] = (.noContent, "")

        try await mark(queue, ActionQueue.touchedLimit + 1)

        XCTAssertEqual(transport.sent.map(\.path), ["/sync/actions", "/profiles/\(UID.n(1))/watch-state/batch"])
        XCTAssertEqual(batches().map { $0.actions.map(\.touched.count) }, [[1, ActionQueue.touchedLimit]])
        let ids = transport.json(.put, "/profiles/\(UID.n(1))/watch-state/batch")?["itemIds"] as? [String]
        XCTAssertEqual(ids?.count, ActionQueue.touchedLimit + 1)
        let left = try await queued(replica)
        XCTAssertEqual(left, [])
        let applied = try await replica.read {
            try UID.fetchAll($0, sql: "SELECT item_id FROM watch_state ORDER BY item_id")
        }
        XCTAssertEqual(applied, [40, .n(ActionQueue.touchedLimit)], "the server's rows come back by sync")
        XCTAssertEqual(kicks.all.count, 2, "a catch-up after each")
    }

    func testAnActionTooLargeToQueueIsNotSentWhileTheQueueBeforeItIsUnsent() async throws {
        let replica = try replica()
        let queue = queue(replica)
        try await watch(queue, item: 40)
        let ids = try await queued(replica)
        transport.hold = { sent in if sent.path == "/sync/actions" { throw URLError(.notConnectedToInternet) } }
        transport.routes["PUT /profiles/\(UID.n(1))/watch-state/batch"] = (.noContent, "")

        do {
            try await mark(queue, ActionQueue.touchedLimit + 1)
            XCTFail("sent ahead of the queue")
        } catch {
            XCTAssertEqual(error as? AppError, .unreachable)
        }

        XCTAssertEqual(transport.sent.map(\.path), ["/sync/actions"])
        let left = try await queued(replica)
        XCTAssertEqual(left, ids)
    }

    func testLargeActionsGoInBatchesThatFitTheRequestBodyLimit() async throws {
        let replica = try replica()
        let queue = queue(replica)
        for _ in 0..<30 { try await mark(queue, ActionQueue.touchedLimit) }
        let ids = try await queued(replica)

        let flushed = await queue.flush()

        XCTAssertEqual(flushed, .done)
        let sizes = transport.sent.filter { $0.path == "/sync/actions" }.map(\.body.utf8.count)
        XCTAssertGreaterThan(sizes.reduce(0, +), ActionQueue.bodyLimit, "the queue holds more than one body")
        XCTAssertTrue(sizes.allSatisfy { $0 <= ActionQueue.bodyLimit }, "\(sizes)")
        XCTAssertEqual(batches().flatMap { $0.actions.map(\.id) }, ids)
    }

    /// putWatchStates of `count` items, each touched; its local write is a
    /// row for item `count`.
    private func mark(_ queue: ActionQueue, _ count: Int) async throws {
        let items = (0..<count).map { UID.n($0 + 1000) }
        try await queue.act(
            as: 1, touching: try items.map { try .row("watch_state", 1, $0) },
            call: { client, at in
                _ = try await client.putWatchStates(
                    path: .init(profileId: 1), body: .json(.init(itemIds: items, watched: true, at: at)))
            },
            apply: { db, _ in
                try db.execute(
                    sql: "INSERT OR IGNORE INTO watch_state VALUES (?, ?, 0)", arguments: [UID.n(1), UID.n(count)])
            })
    }
}
