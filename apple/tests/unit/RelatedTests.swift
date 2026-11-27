import Foundation
import GRDB
import RabbitEarsAPI
import XCTest

@testable import RabbitEarsKit

@MainActor
final class RelatedTests: XCTestCase {
    var fixture: ReplicaFixture!

    override func setUp() { fixture = ReplicaFixture() }
    override func tearDown() { fixture.remove() }

    /// Avery an adult (1) and Kit a kid to PG (3). The Lord of the Rings is
    /// TMDB's, by year; Long ones is the household's own; Elsewhere is
    /// another household's. Alpha's specials come after its seasons.
    private func library(_ rows: (Database) throws -> Void = { _ in }) throws -> Replica {
        try fixture.v1 { db in
            try db.account(1, "Avery")
            try db.account(3, "Kit", kind: "kid", movies: "PG")
            try db.item(33, "movie", "The Hobbit", rating: "PG", year: 2012)
            try db.item(31, "movie", "The Two Towers", rating: "PG-13", year: 2002)
            try db.item(30, "movie", "The Fellowship of the Ring", rating: "PG", year: 2001)
            try db.item(32, "movie", "The Return of the King", rating: "PG-13", year: 2003)
            try db.item(40, "movie", "Heat", rating: "R", year: 1995)
            try db.collection(6, "The Lord of the Rings", source: "tmdb", movies: [33, 31, 30, 32])
            try db.collection(7, "Long ones", movies: [40, 32, 31])
            try db.collection(8, "Elsewhere", household: 9, movies: [31, 40])
            try db.item(10, "show", "Alpha", rating: "TV-14")
            try db.item(16, "season", "Specials", parent: 10, season: 0)
            try db.item(17, "episode", "Extra", parent: 16, season: 0, episode: 1)
            try db.item(14, "season", "Season 2", parent: 10, season: 2)
            try db.item(15, "episode", "Hello", parent: 14, season: 2, episode: 1)
            try db.item(11, "season", "Season 1", parent: 10, season: 1)
            try db.item(13, "episode", "Second", parent: 11, season: 1, episode: 2)
            try db.item(12, "episode", "Pilot", parent: 11, season: 1, episode: 1)
            try rows(db)
        }
    }

    private func model(_ replica: Replica, _ profile: Int64 = 1) -> CatalogModel {
        CatalogModel(client: ServerEndpoint.default.client(token: "t"), replica: replica, profileId: profile)
    }

    func testEachCollectionHoldsItsOtherFilmsInOrderAndTheNeighborsAreNamed() async throws {
        let loaded = await model(try library()).related(31)
        let related = try XCTUnwrap(loaded)
        XCTAssertEqual(related.collections.map(\.collection.name), ["The Lord of the Rings", "Long ones"])
        XCTAssertEqual(related.collections.map { $0.items.map(\.id) }, [[30, 32, 33], [40, 32]])
        XCTAssertEqual(related.collections.map(\.collection.movieCount), [4, 3])
        XCTAssertEqual(related.collections.map(\.collection.source), [.tmdb, .custom])
        XCTAssertEqual(related.collections.map(\.collection.customOrder), [false, false])
        XCTAssertTrue(related.similar.isEmpty)
        XCTAssertEqual(
            related.neighbors.map(\.title), ["Previous: The Fellowship of the Ring", "Next: The Return of the King"])
        XCTAssertEqual(
            related.neighbors.map(\.accessibilityLabel),
            ["Previous film, The Fellowship of the Ring", "Next film, The Return of the King"])
    }

    func testAKidSeesOnlyWhatTheyMayAndTheNeighborsSkipTheRest() async throws {
        let replica = try library()
        let hidden = await model(replica, 3).related(31)
        XCTAssertNil(hidden, "PG-13 is past Kit's ceiling")
        let loaded = await model(replica, 3).related(33)
        let related = try XCTUnwrap(loaded)
        XCTAssertEqual(related.collections.map(\.collection.name), ["The Lord of the Rings"])
        XCTAssertEqual(related.collections.map { $0.items.map(\.id) }, [[30]])
        XCTAssertEqual(related.collections.first?.collection.movieCount, 2)
        XCTAssertEqual(related.previous?.id, 30, "over the two Kit may not see")
        XCTAssertNil(related.next)
    }

    func testACollectionOfMoreThanTenListsTheTenNearestTheFilm() async throws {
        let movies = Array(Int64(100)...114)
        let replica = try library { db in
            for id in movies { try db.item(id, "movie", "Film \(id)", rating: "PG") }
            try db.collection(9, "Marathon", movies: movies, positions: true)
        }
        let early = await model(replica).related(102)
        XCTAssertEqual(early?.collections.first?.items.map(\.id), [100, 101] + Array(Int64(103)...110))
        XCTAssertEqual(early?.collections.first?.collection.customOrder, true)
        let late = await model(replica).related(113)
        XCTAssertEqual(late?.collections.first?.items.map(\.id), Array(Int64(104)...112) + [114])
    }

    func testAnEpisodesNeighborsAreItsCodesInPlayOrderAndItHasNoCollections() async throws {
        let replica = try library()
        let loaded = await model(replica).related(13)
        let related = try XCTUnwrap(loaded)
        XCTAssertTrue(related.collections.isEmpty)
        XCTAssertEqual(related.neighbors.map(\.title), ["Previous: S1 E1", "Next: S2 E1"])
        XCTAssertEqual(related.neighbors.map(\.accessibilityLabel), ["Previous episode, S1 E1", "Next episode, S2 E1"])
        XCTAssertTrue(related.neighbors[1].isNext)
        let last = await model(replica).related(15)
        XCTAssertEqual(last?.previous?.id, 13)
        XCTAssertEqual(last?.next?.id, 17, "specials come last")
    }

    func testAFilmInNoCollectionHasNoCollectionsAndNoNeighbors() async throws {
        let replica = try library { try $0.item(50, "movie", "Alone", rating: "PG") }
        let loaded = await model(replica).related(50)
        let related = try XCTUnwrap(loaded)
        XCTAssertTrue(related.collections.isEmpty)
        XCTAssertTrue(related.neighbors.isEmpty)
    }

    func testAnUnreadReplicaOrAnUnknownTitleIsNoAnswer() async throws {
        let unread = await model(try fixture.open()).related(31)
        XCTAssertNil(unread)
        let unknown = await model(try library()).related(999)
        XCTAssertNil(unknown)
    }

    func testReplacingTheTopPageKeepsTheWayBack() {
        var path = ["home", "fellowship"]
        path.replaceTop(with: "towers")
        XCTAssertEqual(path, ["home", "towers"])
        var empty: [String] = []
        empty.replaceTop(with: "towers")
        XCTAssertEqual(empty, ["towers"])
    }
}
