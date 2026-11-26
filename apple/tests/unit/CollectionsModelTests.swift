import Foundation
import HTTPTypes
import RabbitEarsAPI
import XCTest

@testable import RabbitEarsKit

extension Fixtures {
    static func collection(_ id: Int64, _ name: String, source: String = "custom", count: Int = 0) -> String {
        let owner = source == "custom" ? #""householdId":1,"# : #""tmdbId":\#(id * 100),"overview":"Three of them.","#
        return #"{"id":\#(id),"source":"\#(source)","name":"\#(name)","movieCount":\#(count),\#(owner)"#
            + #""customOrder":false,"createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z"}"#
    }

    /// The same collection with its movies in a hand-made order.
    static func handOrdered(_ collection: String) -> String {
        collection.replacingOccurrences(of: #""customOrder":false"#, with: #""customOrder":true"#)
    }
}

@MainActor
final class CollectionsModelTests: XCTestCase {
    var transport: RoutingTransport!
    var model: CollectionsModel!

    override func setUp() async throws {
        transport = RoutingTransport()
        transport.respond = { sent in
            guard sent.method == .get, sent.path == "/collections" else { return nil }
            return sent.query.contains("offset=200")
                ? (.ok, Fixtures.page([Fixtures.collection(8, "Rainy days", count: 1)], total: 3))
                : (
                    .ok,
                    #"{"items":[\#(Fixtures.collection(6, "Comet saga", source: "tmdb", count: 3)),"#
                        + #"\#(Fixtures.collection(7, "Movie night"))],"total":3,"nextOffset":200}"#
                )
        }
        model = CollectionsModel(
            client: ServerEndpoint(userInput: "192.168.1.9")!.client(token: "t", transport: transport))
        await model.load()
    }

    func testLoadsEveryPageAndPicksOutTheHouseholdsOwn() {
        XCTAssertEqual(model.collections.map(\.id), [6, 7, 8])
        XCTAssertEqual(model.custom.map(\.name), ["Movie night", "Rainy days"])
        XCTAssertEqual(transport.queries(.get, "/collections").count, 2)
        XCTAssertEqual(model.collections.map(\.summary), ["3 movies", "0 movies", "1 movie"])
        XCTAssertNil(model.error)
    }

    func testMoviesAreReadToTheLastPageInTheServersOrder() async throws {
        transport.respond = { sent in
            guard sent.path == "/collections/6/movies" else { return nil }
            return sent.query.contains("offset=200")
                ? (.ok, Fixtures.page([Fixtures.item(12, "movie", "Comet III")]))
                : (
                    .ok,
                    #"{"items":[\#(Fixtures.item(10, "movie", "Comet")),"#
                        + #"\#(Fixtures.item(11, "movie", "Comet II"))],"nextOffset":200}"#
                )
        }
        let read = await model.movies(of: 6)
        XCTAssertEqual(try XCTUnwrap(read).map(\.id), [10, 11, 12])
        let unreadable = await model.movies(of: 99)
        XCTAssertNil(unreadable)
    }

    func testACollectionReachedByALinkIsReadWithItsMovies() async {
        transport.respond = { sent in
            switch sent.path {
            case "/collections/9": return (.ok, Fixtures.collection(9, "Late shows", count: 1))
            case "/collections/9/movies": return (.ok, Fixtures.page([Fixtures.item(10, "movie", "Comet")]))
            default: return nil
            }
        }
        let read = await model.movies(of: 9)
        XCTAssertEqual(read?.map(\.id), [10])
        XCTAssertEqual(model.collections.last?.name, "Late shows")
    }

    func testCreateRenameAndDelete() async throws {
        transport.routes["POST /collections"] = (.created, Fixtures.collection(9, "Snow days"))
        transport.routes["PUT /collections/9"] = (.ok, Fixtures.collection(9, "Snowed in"))
        transport.routes["DELETE /collections/9"] = (.noContent, "")
        let blank = await model.create(name: "  ")
        XCTAssertNil(blank)
        let made = await model.create(name: " Snow days ")
        let created = try XCTUnwrap(made)
        XCTAssertEqual(transport.json(.post, "/collections")?["name"] as? String, "Snow days")
        XCTAssertEqual(model.collections.map(\.id), [6, 7, 8, 9])

        await model.rename(created, to: "Snowed in")
        XCTAssertEqual(transport.json(.put, "/collections/9")?["name"] as? String, "Snowed in")
        XCTAssertEqual(model.collections.last?.name, "Snowed in")

        await model.delete(created)
        XCTAssertEqual(model.collections.map(\.id), [6, 7, 8])
    }

    func testAddingAndRemovingAMovieRefreshesTheCount() async {
        transport.routes["PUT /collections/7/movies/10"] = (.noContent, "")
        transport.routes["DELETE /collections/7/movies/10"] = (.noContent, "")
        transport.routes["GET /collections/7"] = (.ok, Fixtures.collection(7, "Movie night", count: 1))
        let added = await model.add(movie: 10, to: 7)
        XCTAssertTrue(added)
        XCTAssertEqual(model.collections.first { $0.id == 7 }?.movieCount, 1)
        await model.remove(movie: 10, from: 7)
        XCTAssertEqual(transport.paths(.delete), ["/collections/7/movies/10"])
        XCTAssertNil(model.error)
    }

    func testARefusedWriteSaysWhy() async {
        transport.routes["PUT /collections/6/movies/10"] = (
            .forbidden, Fixtures.error("forbidden", "A TMDB collection can't be changed.")
        )
        let added = await model.add(movie: 10, to: 6)
        XCTAssertFalse(added)
        XCTAssertEqual(model.error, "A TMDB collection can't be changed.")
    }

    func testAMoviesCollectionsComeFromItsDetails() async {
        let movie = Fixtures.item(10, "movie", "Comet").dropLast()
        transport.routes["GET /items/10"] = (
            .ok, #"\#(movie),"collections":[\#(Fixtures.collection(6, "Comet saga", source: "tmdb"))]}"#
        )
        transport.routes["GET /items/11"] = (.ok, Fixtures.item(11, "movie", "Loner"))
        let named = await model.collections(of: 10)
        XCTAssertEqual(named.map(\.name), ["Comet saga"])
        let none = await model.collections(of: 11)
        XCTAssertEqual(none, [])
    }

    func testMovingAMovieSendsItsIndexAndTheFlagFollows() async {
        transport.routes["PUT /collections/7/movies/10/position"] = (
            .ok, Fixtures.handOrdered(Fixtures.collection(7, "Movie night", count: 4))
        )
        XCTAssertEqual(model.collections.first { $0.id == 7 }?.isHandOrdered, false)
        let moved = await model.move(10, in: 7, to: 3)
        XCTAssertTrue(moved)
        XCTAssertEqual(transport.json(.put, "/collections/7/movies/10/position")?["position"] as? Int, 3)
        XCTAssertEqual(model.collections.first { $0.id == 7 }?.isHandOrdered, true)
        XCTAssertEqual(model.collections.first { $0.id == 7 }?.movieCount, 4)
        XCTAssertNil(model.error)
    }

    func testResettingTheOrderClearsTheFlag() async {
        transport.routes["PUT /collections/7/movies/10/position"] = (
            .ok, Fixtures.handOrdered(Fixtures.collection(7, "Movie night"))
        )
        transport.routes["DELETE /collections/7/order"] = (.ok, Fixtures.collection(7, "Movie night"))
        await model.move(10, in: 7, to: 0)
        let reset = await model.resetOrder(of: 7)
        XCTAssertTrue(reset)
        XCTAssertEqual(transport.paths(.delete), ["/collections/7/order"])
        XCTAssertEqual(model.collections.first { $0.id == 7 }?.isHandOrdered, false)
    }

    func testARefusedMoveOrResetLeavesTheCollectionAsItWas() async {
        let refusal = (
            HTTPResponse.Status.forbidden, Fixtures.error("forbidden", "A TMDB collection can't be changed.")
        )
        transport.routes["PUT /collections/6/movies/10/position"] = refusal
        transport.routes["DELETE /collections/6/order"] = refusal
        let before = model.collections
        let moved = await model.move(10, in: 6, to: 1)
        XCTAssertFalse(moved)
        XCTAssertEqual(model.error, "A TMDB collection can't be changed.")
        let reset = await model.resetOrder(of: 6)
        XCTAssertFalse(reset)
        XCTAssertEqual(model.collections, before)
        XCTAssertEqual(model.collections.map(\.isHandOrdered), [false, false, false])
    }

    func testReorderingAnswersTheMoviesAsTheServerHoldsThemAndAResetDoesToo() async throws {
        let ids: [Int64] = [11, 12, 10]
        transport.routes["GET /collections/7/movies"] = (
            .ok, Fixtures.page(ids.map { Fixtures.item($0, "movie", "Part \($0)") })
        )
        transport.routes["PUT /collections/7/movies/10/position"] = (
            .ok, Fixtures.handOrdered(Fixtures.collection(7, "Movie night"))
        )
        transport.routes["DELETE /collections/7/order"] = (.ok, Fixtures.collection(7, "Movie night"))
        let moved = await model.reorder(10, in: 7, to: 2)
        XCTAssertEqual(try XCTUnwrap(moved).map(\.id), [11, 12, 10])
        XCTAssertEqual(model.collections.first { $0.id == 7 }?.isHandOrdered, true)
        let reset = await model.restoreReleaseOrder(of: 7)
        XCTAssertNotNil(reset)
        XCTAssertEqual(model.collections.first { $0.id == 7 }?.isHandOrdered, false)
        XCTAssertNil(model.error)
    }

    func testARefusedReorderStillReadsTheServersOrderAndKeepsTheError() async throws {
        transport.routes["PUT /collections/6/movies/10/position"] = (
            .forbidden, Fixtures.error("forbidden", "A TMDB collection can't be changed.")
        )
        transport.routes["GET /collections/6/movies"] = (.ok, Fixtures.page([Fixtures.item(10, "movie", "Comet")]))
        let read = await model.reorder(10, in: 6, to: 0)
        XCTAssertEqual(try XCTUnwrap(read).map(\.id), [10])
        XCTAssertEqual(model.error, "A TMDB collection can't be changed.")
    }

    func testARowReadsItsYearAndRuntime() {
        let movie: Item = Fixtures.decode(Fixtures.item(10, "movie", "Comet", runtime: 124, year: 2016))
        XCTAssertEqual(CollectionsModel.detail(of: movie), "2016 · 2h 4m")
        XCTAssertEqual(CollectionsModel.detail(of: Fixtures.decode(Fixtures.item(11, "movie", "Comet II"))), "")
    }

    func testACopyStoredBeforeTheFlagExistedReadsAsReleaseOrder() throws {
        let stored = Fixtures.collection(7, "Movie night").replacingOccurrences(of: #""customOrder":false,"#, with: "")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let collection = try decoder.decode(MovieCollection.self, from: Data(stored.utf8))
        XCTAssertNil(collection.customOrder)
        XCTAssertFalse(collection.isHandOrdered)
    }

    func testADropOffsetBelowTheOldPlaceCountsTheMovieItself() {
        XCTAssertEqual(CollectionsModel.position(moving: 1, toOffset: 4), 3)
        XCTAssertEqual(CollectionsModel.position(moving: 3, toOffset: 1), 1)
        XCTAssertEqual(CollectionsModel.position(moving: 2, toOffset: 3), 2)
        XCTAssertEqual(CollectionsModel.position(moving: 2, toOffset: 2), 2)
    }

    func testMoviesKeepTheServersOrderWhateverTheirYears() async throws {
        let ids: [Int64] = [12, 10, 11]
        let page = Fixtures.page(ids.map { Fixtures.item($0, "movie", "Part \($0)") })
        transport.routes["GET /collections/7/movies"] = (.ok, page)
        let read = await model.movies(of: 7)
        XCTAssertEqual(try XCTUnwrap(read).map(\.id), [12, 10, 11])
    }

    func testADownloadedHandOrderedCollectionReadsOfflineWithItsBadgeAndOrder() async throws {
        let harness = DownloadHarness()
        harness.objects["GET /me"] = Fixtures.me
        harness.objects["GET /items/20"] = Fixtures.item(20, "movie", "Dune", runtime: 166)
        harness.objects["GET /items/21"] = Fixtures.item(21, "movie", "Arrival", runtime: 116)
        harness.objects["GET /collections/3"] = Fixtures.handOrdered(Fixtures.collection(3, "Slow burns", count: 2))
        harness.objects["GET /collections/3/movies"] = Fixtures.page(
            [Fixtures.item(21, "movie", "Arrival"), Fixtures.item(20, "movie", "Dune")])
        harness.resolves["collection/3"] = [
            Fixtures.downloadTitle(20, "movie"), Fixtures.downloadTitle(21, "movie"),
        ]
        _ = try await harness.client.getMe()
        try await harness.download(.init(scope: .collection, id: 3, name: "Slow burns", standing: true))
        for _ in 0..<400 where harness.store.ledger.shelf.collections[3] == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        harness.goOffline()
        let offline = CollectionsModel(client: harness.client)
        await offline.load()
        XCTAssertEqual(offline.collections.map(\.isHandOrdered), [true])
        let movies = await offline.movies(of: 3)
        XCTAssertEqual(movies?.map(\.id), [21, 20])
        // Nothing on the device answers a write, so an edit fails as the server not answering.
        let moved = await offline.move(21, in: 3, to: 1)
        XCTAssertFalse(moved)
        XCTAssertNotNil(offline.error)
    }
}
