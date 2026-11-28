import Foundation
import GRDB
import RabbitEarsAPI
import XCTest

@testable import RabbitEarsKit

/// SyncEndToEndTests of favorites: starred offline, sent, and read on another device.
extension SyncEndToEndTests {
    func testAStarMadeOfflineReachesTheServerAtItsInstantAndAnotherDevice() async throws {
        let other = try device(token: try await server.signIn("e2e other device"))
        let device = try device()
        let (adult, rest) = (server.adult, server.adult.rest)
        let movie = try server.movie("Golden Hour")
        let show = try server.item("The Guild", .show)
        try await device.engine.catchUp()

        try await device.queue.putFavorite(item: movie, as: adult.id)
        try await device.queue.putFavorite(item: show, as: adult.id)
        let unsent = try await device.queued()
        XCTAssertEqual(unsent, 2, "nothing sent")
        let starredAt = try await device.replica.read { db in
            try Int64.fetchOne(
                db, sql: "SELECT created_at FROM favorite WHERE account_id = ? AND item_id = ?",
                arguments: [adult.id, movie])
        }
        let flushed = await device.queue.flush()
        XCTAssertEqual(flushed, .done)

        let served = try await rest.listFavorites(path: .init(profileId: adult.id)).ok.body.json.items
        XCTAssertEqual(
            served.first { $0.itemId == movie }.map { ActionQueue.ms($0.createdAt) }, starredAt,
            "the server keeps the instant of the action")
        try await other.engine.catchUp()
        let shelves = try await other.replica.read { try Favorites.shelves($0, profile: adult.id, only: nil) }
        XCTAssertEqual(shelves.movies.map(\.id), served.filter { $0.kind == .movie }.map { $0.itemId })
        XCTAssertEqual(shelves.shows.map(\.id), served.filter { $0.kind == .show }.map { $0.itemId })
        XCTAssertTrue(shelves.movies.contains { $0.id == movie })

        for item in [movie, show] {
            _ = try await rest.deleteFavorite(path: .init(profileId: adult.id, itemId: item)).noContent
        }
        try await other.engine.catchUp()
        let left = try await other.replica.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM favorite WHERE account_id = ?", arguments: [adult.id])
        }
        XCTAssertEqual(left, 0, "the unstars arrive as tombstones")
    }
}
