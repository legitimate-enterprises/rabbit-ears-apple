import Foundation
import GRDB
import RabbitEarsAPI
import XCTest

@testable import RabbitEarsKit

/// Movies and shows sort by the server's sort title, ignoring case, else by the title shown.
@MainActor
final class SortTitleTests: XCTestCase {
    var fixture: ReplicaFixture!

    override func setUp() { fixture = ReplicaFixture() }
    override func tearDown() { fixture.remove() }

    /// The server's sort titles, where it sent one.
    private let sorts: [UID: String] = [
        1: "Matrix", 2: "Quiet Place", 3: "Die Hard", 4: "2001", 5: "bourne identity", 7: "Expanse",
    ]
    /// Casablanca (6) has no sort title, as from an older server, and shows a title it was not parsed with.
    private let byTitle: [UID] = [4, 5, 6, 3, 1, 2]

    func testTheGridOrdersBySortTitleIgnoringCaseElseByTheTitleShown() {
        let titles: [UID: String] = [
            1: "The Matrix", 2: "A Quiet Place", 3: "Die Hard", 4: "2001", 5: "The Bourne Identity", 6: "zz",
            7: "The Expanse",
        ]
        let items = titles.keys.sorted().map { id in
            var item = Fixtures.decode(Fixtures.item(id, id == 7 ? "show" : "movie", titles[id]!), as: Item.self)
            item.sortTitle = sorts[id]
            if id == 6 { item.metadata?.title = "Casablanca" }
            return item
        }
        let catalog = Catalog(items: items)
        XCTAssertEqual(catalog.grid(.movie, sort: .title).map(\.id), byTitle)
        XCTAssertEqual(Catalog.sortTitle(items[0]), "Matrix")
        XCTAssertEqual(Catalog.sortTitle(items[5]), "Casablanca")
    }

    func testASyncedSortTitleIsWhatTheReplicasReadsOrderBy() async throws {
        let replica = try fixture.v1 { db in
            try db.account(1, "Avery")
            try db.person(9, "Everyone", tmdb: 90)
            for (id, title) in [
                (1, "The Matrix"), (2, "A Quiet Place"), (3, "Die Hard"), (4, "2001"), (5, "The Bourne Identity"),
                (6, "zz"),
            ] as [(UID, String)] {
                try db.item(id, "movie", title, rating: "PG", year: 2000)
                try db.credit(.new(), item: id, person: 9, kind: "cast", position: 0)
            }
            try db.execute(
                sql: "UPDATE item_metadata SET title = 'Casablanca' WHERE item_id = ?", arguments: [UID.n(6)])
            for (id, sort) in sorts {
                try db.execute(sql: "UPDATE item SET sort_title = ? WHERE id = ?", arguments: [sort, id])
            }
            try db.collection(8, "Year 2000", source: "tmdb", movies: [1, 2, 3, 4, 5, 6])
        }
        let model = CatalogModel(
            client: ServerEndpoint.default.client(token: "t", transport: RoutingTransport()), replica: replica,
            profileId: 1)
        await model.load()
        XCTAssertEqual(model.catalog.item(1)?.sortTitle, "Matrix")
        XCTAssertNil(model.catalog.item(6)?.sortTitle)
        XCTAssertEqual(model.catalog.grid(.movie, sort: .title).map(\.id), byTitle)
        let person = await model.person(9)
        XCTAssertEqual(person?.1.map(\.id), byTitle, "a person's titles")

        let collections = CollectionsModel(
            replica: replica, queue: ActionQueue(replica: replica, client: model.client), profileId: 1)
        let movies = await collections.movies(of: 8)
        XCTAssertEqual(movies?.map(\.id), byTitle, "released together, by sort title")
    }
}
