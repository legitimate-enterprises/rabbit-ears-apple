import GRDB
import XCTest

@testable import RabbitEarsAPI
@testable import RabbitEarsKit

/// Kids' content under Hide kids' content: the Kids pill still reaches it,
/// and nothing else does.
@MainActor
final class KidsHiddenTests: XCTestCase {
    var fixture: ReplicaFixture!

    override func setUp() { fixture = ReplicaFixture() }
    override func tearDown() { fixture.remove() }

    /// Avery (2), hiding kids' content or not, over two grown-up titles and
    /// Bluey's movie and show.
    private func model(hiding: Bool) async throws -> CatalogModel {
        let replica = try fixture.v1 { db in
            try db.account(2, "Avery", hidingKids: hiding)
            try db.account(7, "Robin")
            try db.item(20, "movie", "Dune", rating: "PG-13", genres: [(878, "Science Fiction")])
            try db.item(10, "show", "Severance", rating: "TV-MA")
            try db.item(60, "movie", "Bluey Movie", rating: "G", genres: [(10751, "Family")], kids: true)
            try db.item(50, "show", "Bluey", rating: "TV-Y", kids: true)
            try db.item(51, "season", "Season 1", parent: 50, season: 1)
            try db.item(501, "episode", "Magic Xylophone", parent: 51, season: 1, episode: 1)
            try db.item(502, "episode", "Hotel", parent: 51, season: 1, episode: 2)
        }
        let model = CatalogModel(
            client: ServerEndpoint.default.client(token: "t", transport: RoutingTransport()), replica: replica,
            profileId: 2, hidingKids: hiding)
        await model.load()
        return model
    }

    func testWithHideOffThePillFiltersTheCatalog() async throws {
        let model = try await model(hiding: false)
        XCTAssertEqual(model.catalog.grid(.movie, filter: .kids).map(\.id), [60])
        XCTAssertEqual(model.catalog.total(.movie, filter: .kids), 1)
        XCTAssertEqual(model.catalog.total(.movie), 2)
    }

    func testWithHideOnKidsTitlesAreHeldApartForThePillAndNothingElseSeesThem() async throws {
        let model = try await model(hiding: true)
        XCTAssertEqual(model.catalog.grid(.movie, filter: .kids).map(\.id), [60])
        XCTAssertEqual(model.catalog.grid(.show, filter: .kids).map(\.id), [50])
        XCTAssertEqual(model.catalog.total(.movie, filter: .kids), 1)

        // Opening and playing one works: its tree is there.
        XCTAssertNotNil(model.catalog.item(60))
        XCTAssertEqual(model.catalog.children(of: 50).map(\.id), [51])
        XCTAssertEqual(model.catalog.episodes(under: 50).map(\.id), [501, 502])
        XCTAssertEqual(model.catalog.resumeTarget(for: 50)?.id, 501)

        // Nowhere else.
        XCTAssertEqual(model.catalog.grid(.movie).map(\.id), [20])
        XCTAssertEqual(model.catalog.grid(.movie, filter: .unwatched).map(\.id), [20])
        XCTAssertEqual(model.catalog.grid(.show).map(\.id), [10])
        XCTAssertEqual(model.catalog.total(.movie), 1)
        XCTAssertEqual(model.catalog.total(.show), 1)
        XCTAssertEqual(model.catalog.recentlyAdded.map(\.id).sorted(), [10, 20])
        XCTAssertEqual(model.catalog.genres(.movie).map(\.name), ["Science Fiction"])

        // Watching one does not put it on Home either.
        var catalog = model.catalog
        catalog.record(Fixtures.decode(Fixtures.watch(501, position: 60_000), as: WatchState.self))
        catalog.record(Fixtures.decode(Fixtures.watch(60, position: 60_000), as: WatchState.self))
        XCTAssertEqual(catalog.continueWatching.map(\.id), [])
        catalog.record(
            Fixtures.decode(Fixtures.watch(501, watched: true, played: "2026-05-01T00:00:00Z"), as: WatchState.self))
        XCTAssertEqual(catalog.nextUp.map(\.id), [])
    }

    private func profile(_ id: Int64, hiding: Bool) -> Account {
        Fixtures.decode(String(Fixtures.account(id, "Avery").dropLast()) + #","hideKidsContent":\#(hiding)}"#)
    }

    private func hide(_ hiding: Bool, _ model: CatalogModel) async throws {
        try await model.replica.write {
            try $0.execute(sql: "UPDATE account SET hide_kids_content = ? WHERE id = 2", arguments: [hiding])
        }
    }

    func testAChangedHideOnAnotherDeviceReadsTheReplicaAgain() async throws {
        let model = try await model(hiding: true)
        try await hide(false, model)
        await model.profileChanged(profile(2, hiding: false))
        XCTAssertTrue(model.catalog.grid(.movie).map(\.id).contains(60), "everything is browsable again")
        XCTAssertFalse(model.hidingKids)

        try await hide(true, model)
        await model.profileChanged(profile(2, hiding: true))
        XCTAssertEqual(model.catalog.grid(.movie).map(\.id), [20])
        XCTAssertEqual(model.catalog.grid(.movie, filter: .kids).map(\.id), [60])
        XCTAssertTrue(model.hidingKids)
    }

    func testAnotherProfilesChangeIsNotThisCatalogs() async throws {
        let model = try await model(hiding: false)
        let revision = model.revision
        await model.profileChanged(profile(7, hiding: true))
        XCTAssertFalse(model.hidingKids)
        XCTAssertEqual(model.revision, revision, "not read again")
    }
}
