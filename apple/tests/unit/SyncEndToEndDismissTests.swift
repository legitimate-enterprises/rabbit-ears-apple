import Foundation
import GRDB
import RabbitEarsAPI
import XCTest

@testable import RabbitEarsKit

/// SyncEndToEndTests of dismissing a title from in progress.
extension SyncEndToEndTests {
    func testADismissQueuedHereForgetsOnlyThePositionOnTheServer() async throws {
        let device = try device()
        let (adult, rest) = (server.adult, server.adult.rest)
        let movie = try server.movie("Blue Horizon")
        _ = try await rest.putWatchState(
            path: .init(profileId: adult.id, itemId: movie),
            body: .json(.init(watched: true, positionMs: 61_000, at: Date()))
        ).ok
        let before = try await Served.watchState(rest, adult.id, movie)
        try await device.engine.catchUp()

        try await device.queue.dismissWatchState(item: movie, as: adult.id)
        let here = try await device.position(adult.id, movie)
        XCTAssertEqual(here, 0, "out of progress at once")
        let flushed = await device.queue.flush()
        XCTAssertEqual(flushed, .done)

        let served = try await Served.watchState(rest, adult.id, movie)
        let after = try XCTUnwrap(served)
        XCTAssertEqual(after.positionMs, 0)
        XCTAssertEqual(after.watched, true)
        XCTAssertEqual(after.playCount, before?.playCount)
        try await device.engine.catchUp()
        let mine = try await device.replica.read { db in
            try Row.fetchOne(
                db, sql: "SELECT * FROM watch_state WHERE account_id = ? AND item_id = ?",
                arguments: [adult.id, movie]
            ).map(ReplicaRows.watchState)
        }
        Parity.value(mine, Optional(after), "the dismissed state")
        _ = try await rest.deleteWatchState(path: .init(profileId: adult.id, itemId: movie), query: .init(at: Date()))
            .noContent
    }
}
