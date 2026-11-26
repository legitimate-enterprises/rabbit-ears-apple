import Foundation
import HTTPTypes
import RabbitEarsAPI
import XCTest

@testable import RabbitEarsKit

private func occasion(_ id: Int64, _ name: String, headline: String? = nil) -> String {
    let phrase = headline.map { #""headline":"\#($0)","# } ?? ""
    let dates = #""anchorDate":"2026-12-25","firstDate":"2026-12-01","lastDate":"2026-12-31""#
    return #"{"id":\#(id),"name":"\#(name)",\#(phrase)\#(dates)}"#
}

/// Answers each occasion's titles; Christmas (1) has more than a shelf holds.
/// Built off the main actor, since the transport calls it from elsewhere.
private func titles(failing: Int64? = nil) -> @Sendable (RoutingTransport.Sent) -> (HTTPResponse.Status, String)? {
    { sent in
        guard sent.path == "/items" else { return nil }
        if sent.query.contains("occasionId=\(failing ?? 0)") {
            return (.internalServerError, Fixtures.error("internal"))
        }
        if sent.query.contains("occasionId=1") {
            return (.ok, Fixtures.page((1...25).map { Fixtures.item(Int64(100 + $0), "movie", "Elf \($0)") }))
        }
        return (.ok, Fixtures.page([Fixtures.item(200, "show", "Spooky")]))
    }
}

@MainActor
final class OccasionsModelTests: XCTestCase {
    var transport: RoutingTransport!
    var model: OccasionsModel!
    var client: Client { ServerEndpoint(userInput: "192.168.1.9")!.client(token: "t", transport: transport) }
    let eastern = TimeZone(identifier: "America/New_York")!

    override func setUp() async throws {
        model = OccasionsModel()
        transport = RoutingTransport([
            "GET /profiles/1/occasions": (
                .ok, #"{"items":[\#(occasion(2, "Halloween  Nights")),\#(occasion(1, "Christmas"))]}"#
            )
        ])
        transport.respond = titles()
    }

    func testTheServersOrderAndNamesAreKept() async {
        await model.load(client: client, profileId: 1)
        XCTAssertEqual(model.shelves.map(\.name), ["Halloween  Nights", "Christmas"])
        XCTAssertEqual(model.shelves.first?.items.map(\.id), [200])
    }

    func testTheRequestCarriesTheLocalDay() async {
        // 03:30 UTC on the 22nd is still the 21st in New York.
        let now = ISO8601DateFormatter().date(from: "2026-11-22T03:30:00Z")!
        await model.load(client: client, profileId: 1, now: now, timeZone: eastern)
        XCTAssertEqual(transport.queries(.get, "/profiles/1/occasions"), ["date=2026-11-21"])
        await model.load(client: client, profileId: 1, now: now, timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertEqual(transport.queries(.get, "/profiles/1/occasions").last, "date=2026-11-22")
    }

    func testEachShelfAsksForAsManyTilesAsRecentlyAddedShows() async {
        await model.load(client: client, profileId: 1)
        let asked = transport.queries(.get, "/items").filter { $0.contains("occasionId=1") }
        XCTAssertEqual(asked.first?.contains("limit=\(Catalog.homeShelfLimit)"), true)
        XCTAssertEqual(Catalog.homeShelfLimit, 20)
    }

    func testNothingInSeasonShowsNothing() async {
        transport.routes["GET /profiles/1/occasions"] = (.ok, #"{"items":[]}"#)
        await model.load(client: client, profileId: 1)
        XCTAssertTrue(model.shelves.isEmpty)
        XCTAssertTrue(transport.queries(.get, "/items").isEmpty)
    }

    func testAFailedRequestKeepsWhatShows() async {
        await model.load(client: client, profileId: 1)
        transport.routes["GET /profiles/1/occasions"] = (.internalServerError, Fixtures.error("internal"))
        await model.load(client: client, profileId: 1)
        XCTAssertEqual(model.shelves.map(\.name), ["Halloween  Nights", "Christmas"])
    }

    func testAFailedTitlesRequestDropsOnlyThatOccasion() async {
        transport.respond = titles(failing: 2)
        await model.load(client: client, profileId: 1)
        XCTAssertEqual(model.shelves.map(\.name), ["Christmas"])
    }
}

@MainActor
final class OccasionRowTitleTests: XCTestCase {
    func testAHeadlineTitlesTheRowAndTheNameTitlesWhenThereIsNone() async {
        let transport = RoutingTransport([
            "GET /profiles/1/occasions": (
                .ok, #"{"items":[\#(occasion(1, "Christmas", headline: "Ho, Ho, Ho!")),\#(occasion(2, "Halloween"))]}"#
            )
        ])
        transport.respond = titles()
        let model = OccasionsModel()
        await model.load(
            client: ServerEndpoint(userInput: "192.168.1.9")!.client(token: "t", transport: transport), profileId: 1)
        XCTAssertEqual(model.shelves.map(\.title), ["Ho, Ho, Ho!", "Halloween"])
        XCTAssertEqual(model.shelves.map(\.name), ["Christmas", "Halloween"])
    }

    func testABlankHeadlineIsNoHeadline() {
        let blank = try? JSONDecoder().decode(
            ActiveOccasion.self, from: Data(occasion(1, "Christmas", headline: " ").utf8))
        XCTAssertEqual(blank?.rowTitle, "Christmas")
    }
}

@MainActor
final class OccasionMembersTests: XCTestCase {
    private func model(_ transport: RoutingTransport) -> CatalogModel {
        CatalogModel(
            client: ServerEndpoint(userInput: "192.168.1.9")!.client(token: "t", transport: transport), profileId: 1)
    }

    /// Built off the main actor, as the transport calls it from elsewhere.
    private nonisolated static let pagedMembers: @Sendable (RoutingTransport.Sent) -> (HTTPResponse.Status, String)? = {
        sent in
        guard sent.path == "/items" else { return nil }
        let first = !sent.query.contains("offset=200")
        let rows = first ? Array(1...200) : [201, 202]
        let items = rows.map { Fixtures.item(Int64($0), "movie", "Elf \($0)") }.joined(separator: ",")
        return (.ok, #"{"items":[\#(items)],"total":202\#(first ? #","nextOffset":200"# : "")}"#)
    }

    private nonisolated static let otherMembers: @Sendable (RoutingTransport.Sent) -> (HTTPResponse.Status, String)? = {
        sent in
        guard sent.path == "/items" else { return nil }
        if sent.query.contains("occasionId=2") { return (.ok, Fixtures.page([Fixtures.item(31, "movie", "Elf")])) }
        return (.ok, Fixtures.page([Fixtures.item(31, "movie", "Elf"), Fixtures.item(32, "movie", "Home Alone")]))
    }

    func testTheOccasionScreenPagesEveryMemberTheProfileCanSee() async {
        let transport = RoutingTransport()
        transport.respond = Self.pagedMembers
        let pager = model(transport).occasionMembers(1)
        await pager.loadAll()
        XCTAssertEqual(pager.items.count, 202)
        XCTAssertTrue(transport.queries(.get, "/items").allSatisfy { $0.contains("occasionId=1") })
    }

    func testATitlesDetailsRowHoldsTheOtherMembersOfEachOccasionItIsIn() async {
        let transport = RoutingTransport([
            "GET /profiles/1/occasions": (
                .ok, #"{"items":[\#(occasion(1, "Christmas")),\#(occasion(2, "Halloween"))]}"#
            )
        ])
        transport.respond = Self.otherMembers
        let rows = await model(transport).occasionRows(
            containing: 31, now: ISO8601DateFormatter().date(from: "2026-12-10T12:00:00Z")!,
            timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertEqual(rows.map(\.name), ["Christmas"])
        XCTAssertEqual(rows.first?.items.map(\.id), [32])
        XCTAssertEqual(transport.queries(.get, "/profiles/1/occasions"), ["date=2026-12-10&itemId=31"])
    }
}
