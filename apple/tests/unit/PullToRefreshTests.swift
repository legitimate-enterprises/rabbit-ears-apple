import Foundation
import RabbitEarsAPI
import XCTest

@testable import RabbitEarsKit

/// A pull catches the replica up with the server, and returns once the new data is in.
@MainActor
final class PullToRefreshTests: XCTestCase {
    var app: SyncedApp!

    override func setUp() async throws {
        app = try SyncedApp { db in
            try db.account(1, "Avery")
            try db.item(20, "movie", "Dune")
        }
    }

    override func tearDown() { app.remove() }

    /// The server's next diff adds Flow.
    private func addsFlow() {
        app.routes.respond = { sent in
            guard sent.path == "/sync/changes" else { return nil }
            let item = SyncFixture.Table(
                "item", #"["id","library_id","kind","parsed_title","added_at"]"#,
                #"[["\#(UID.n(21))","\#(UID.n(1))","movie","Flow",0]]"#)
            return (.ok, SyncFixture.diff(version: 2, tables: [item]))
        }
    }

    func testAPullReturnsOnlyOnceTheCatalogHasTheServersChange() async throws {
        let sync = try await app.synced()
        let model = CatalogModel(client: try XCTUnwrap(app.model.client), replica: sync.replica, profileId: 1)
        await model.load()
        XCTAssertNotNil(model.catalog.item(20))
        addsFlow()
        await app.model.pull { await model.load() }
        XCTAssertNotNil(model.catalog.item(21))
    }

    func testAPullTheSystemCancelsStillFinishesApplyingTheNewData() async throws {
        let sync = try await app.synced()
        let model = CatalogModel(client: try XCTUnwrap(app.model.client), replica: sync.replica, profileId: 1)
        await model.load()
        addsFlow()
        let pull = Task { await app.model.pull { await model.load() } }
        pull.cancel()
        await pull.value
        XCTAssertNotNil(model.catalog.item(21))
    }

    func testAFailedPullKeepsWhatWasShown() async throws {
        let sync = try await app.synced()
        let model = CatalogModel(client: try XCTUnwrap(app.model.client), replica: sync.replica, profileId: 1)
        await model.load()
        app.routes.respond = nil
        app.routes.routes["GET /sync/changes"] = (.internalServerError, Fixtures.error("internal"))
        await app.model.pull { await model.load() }
        XCTAssertNotNil(model.catalog.item(20), "the replica stands in while the server fails")
    }
}
