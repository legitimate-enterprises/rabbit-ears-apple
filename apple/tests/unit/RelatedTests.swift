import Foundation
import HTTPTypes
import RabbitEarsAPI
import XCTest

@testable import RabbitEarsKit

@MainActor
final class RelatedTests: XCTestCase {
    private func model(_ routes: [String: (HTTPResponse.Status, String)]) -> CatalogModel {
        CatalogModel(
            client: ServerEndpoint.default.client(token: "t", transport: RoutingTransport(routes)), profileId: 2)
    }

    func testEachCollectionHoldsItsOtherFilmsInOrderAndTheNeighborsAreNamed() async throws {
        let fellowship = Fixtures.item(30, "movie", "The Fellowship of the Ring")
        let king = Fixtures.item(32, "movie", "The Return of the King")
        let answer =
            #"{"collections":[{"collection":\#(Fixtures.collection(6, "The Lord of the Rings", source: "tmdb")),"#
            + #""items":[\#(fellowship),\#(king)]},"#
            + #"{"collection":\#(Fixtures.collection(7, "Long ones")),"#
            + #""items":[\#(king),\#(Fixtures.item(40, "movie", "Heat"))]}],"#
            + #""similar":[],"previous":\#(fellowship),"next":\#(king)}"#
        let loaded = await model(["GET /items/31/related": (.ok, answer)]).related(31)
        let related = try XCTUnwrap(loaded)
        XCTAssertEqual(related.collections.map(\.collection.name), ["The Lord of the Rings", "Long ones"])
        XCTAssertEqual(related.collections.map { $0.items.map(\.id) }, [[30, 32], [32, 40]])
        XCTAssertEqual(
            related.neighbors.map(\.title), ["Previous: The Fellowship of the Ring", "Next: The Return of the King"])
        XCTAssertEqual(
            related.neighbors.map(\.accessibilityLabel),
            ["Previous film, The Fellowship of the Ring", "Next film, The Return of the King"])
    }

    func testAnEpisodesNeighborsAreItsCodesAndItHasNoCollections() async throws {
        let answer =
            #"{"collections":[],"similar":[],"#
            + #""next":\#(Fixtures.item(201, "episode", "Hello", parent: 12, season: 2, episode: 1))}"#
        let loaded = await model(["GET /items/102/related": (.ok, answer)]).related(102)
        let related = try XCTUnwrap(loaded)
        XCTAssertTrue(related.collections.isEmpty)
        XCTAssertNil(related.previous)
        XCTAssertEqual(related.neighbors.map(\.title), ["Next: S2 E1"])
        XCTAssertEqual(related.neighbors.map(\.accessibilityLabel), ["Next episode, S2 E1"])
        XCTAssertTrue(related.neighbors[0].isNext)
    }

    func testAnEmptyAnswerHasNoCollectionsAndNoNeighbors() async throws {
        let loaded = await model(["GET /items/20/related": (.ok, #"{"collections":[],"similar":[]}"#)]).related(20)
        let related = try XCTUnwrap(loaded)
        XCTAssertTrue(related.collections.isEmpty)
        XCTAssertTrue(related.neighbors.isEmpty)
    }

    func testAFailedOrRefusedReadIsNoAnswer() async {
        let failed = await model(["GET /items/20/related": (.internalServerError, Fixtures.error("internal"))])
            .related(20)
        XCTAssertNil(failed)
        let hidden = await model(["GET /items/20/related": (.notFound, Fixtures.error("not_found"))]).related(20)
        XCTAssertNil(hidden)
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
