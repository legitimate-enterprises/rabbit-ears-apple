import HTTPTypes
import XCTest

@testable import RabbitEarsAPI
@testable import RabbitEarsKit

/// Kids' content under Hide kids' content: the Kids pill still reaches it,
/// and nothing else does.
@MainActor
final class KidsHiddenTests: XCTestCase {
    private let adultMovie = Fixtures.item(20, "movie", "Dune", rating: "PG-13", genres: [(878, "Science Fiction")])
    private let adultShow = Fixtures.item(10, "show", "Severance", rating: "TV-MA")
    private let kidsMovie = Fixtures.item(
        60, "movie", "Bluey Movie", rating: "G", genres: [(10751, "Family")], kids: true)
    private let kidsShow = Fixtures.item(50, "show", "Bluey", rating: "TV-Y", kids: true)
    private let kidsSeason = Fixtures.item(51, "season", "Season 1", parent: 50, season: 1)
    private let kidsEpisode = Fixtures.item(501, "episode", "Magic Xylophone", parent: 51, season: 1, episode: 1)
    private let kidsEpisode2 = Fixtures.item(502, "episode", "Hotel", parent: 51, season: 1, episode: 2)

    /// What the server lists: kids' content only for `kidsContent=true` when the profile hides it,
    /// and with every title otherwise.
    private func serve(hiding: Bool) -> RoutingTransport {
        let transport = RoutingTransport(["GET /profiles/2/watch-state": (.ok, Fixtures.page([]))])
        transport.respond = respond(hiding: hiding)
        return transport
    }

    private func respond(hiding: Bool) -> (RoutingTransport.Sent) -> (HTTPResponse.Status, String)? {
        // Answers by kind and by kidsContent; the transport asks off the main actor, so the closure
        // holds finished pages and no closure of its own.
        let kids: [String: [String]] = [
            "movie": [kidsMovie], "show": [kidsShow], "season": [kidsSeason], "episode": [kidsEpisode, kidsEpisode2],
        ]
        let adults: [String: [String]] = ["movie": [adultMovie], "show": [adultShow]]
        var pages: [String: String] = [:]
        for kind in ["movie", "show", "season", "episode"] {
            pages["\(kind)/kids"] = Fixtures.page(kids[kind] ?? [])
            pages["\(kind)/all"] = Fixtures.page((adults[kind] ?? []) + (hiding ? [] : kids[kind] ?? []))
        }
        return { [pages] sent in
            guard sent.path == "/items" else { return nil }
            let which = sent.query.contains("kidsContent=true") ? "kids" : "all"
            for kind in ["movie", "show", "season", "episode"] where sent.query.contains("kind=\(kind)") {
                return (.ok, pages["\(kind)/\(which)"] ?? Fixtures.page([]))
            }
            return (.ok, Fixtures.page([]))
        }
    }

    private func model(_ transport: RoutingTransport, hiding: Bool) -> CatalogModel {
        CatalogModel(
            client: ServerEndpoint.default.client(token: "t", transport: transport), profileId: 2, hidingKids: hiding)
    }

    private func kidsRequests(_ transport: RoutingTransport) -> [String] {
        transport.queries(.get, "/items").filter { $0.contains("kidsContent=true") }
    }

    func testWithHideOffThePillFiltersTheCatalogAndAsksForNothingMore() async {
        let transport = serve(hiding: false)
        let model = model(transport, hiding: false)
        await model.load()
        await model.showKids(.movie)
        XCTAssertTrue(kidsRequests(transport).isEmpty)
        XCTAssertEqual(model.catalog.grid(.movie, filter: .kids).map(\.id), [60])
        XCTAssertEqual(model.catalog.total(.movie, filter: .kids), 1)
        XCTAssertEqual(model.catalog.total(.movie), 2)
    }

    func testWithHideOnThePillReadsKidsTitlesApartAndNothingElseSeesThem() async throws {
        let transport = serve(hiding: true)
        let model = model(transport, hiding: true)
        await model.load()
        XCTAssertTrue(kidsRequests(transport).isEmpty, "without the pill nothing of kids' is asked for")
        XCTAssertEqual(model.catalog.grid(.movie, filter: .kids).map(\.id), [])

        await model.showKids(.movie)
        await model.showKids(.show)
        XCTAssertEqual(kidsRequests(transport).count, 4, "movies, then shows with their seasons and episodes")
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

    func testThePillAsksOncePerKindAndAReloadKeepsWhatItAsked() async {
        let transport = serve(hiding: true)
        let model = model(transport, hiding: true)
        await model.load()
        await model.showKids(.movie)
        await model.showKids(.movie)
        XCTAssertEqual(kidsRequests(transport).count, 1)
        await model.load()
        XCTAssertEqual(kidsRequests(transport).count, 2, "read again with the catalog")
        XCTAssertEqual(model.catalog.grid(.movie, filter: .kids).map(\.id), [60])
        XCTAssertEqual(model.catalog.grid(.show, filter: .kids).map(\.id), [], "shows were never asked for")
    }

    func testAFailedReadKeepsTheErrorAndIsAskedAgainNextTime() async {
        let transport = serve(hiding: true)
        let model = model(transport, hiding: true)
        await model.load()
        transport.failure = AppError.server("down")
        await model.showKids(.movie)
        XCTAssertNotNil(model.error)
        transport.failure = nil
        await model.showKids(.movie)
        XCTAssertEqual(model.catalog.grid(.movie, filter: .kids).map(\.id), [60])
    }

    private func profile(_ id: Int64, hiding: Bool) -> Account {
        Fixtures.decode(String(Fixtures.account(id, "Avery").dropLast()) + #","hideKidsContent":\#(hiding)}"#)
    }

    func testAChangedHideOnAnotherDeviceReloadsAndDropsWhatWasHeldApart() async {
        let transport = serve(hiding: true)
        let model = model(transport, hiding: true)
        await model.load()
        await model.showKids(.movie)
        XCTAssertNotNil(model.catalog.item(60))
        let before = transport.queries(.get, "/items").count

        await model.profileChanged(profile(2, hiding: true))
        XCTAssertEqual(transport.queries(.get, "/items").count, before, "unchanged: no reload")

        transport.respond = respond(hiding: false)
        await model.profileChanged(profile(2, hiding: false))
        XCTAssertTrue(model.catalog.grid(.movie).map(\.id).contains(60), "everything is browsable again")
        XCTAssertFalse(model.hidingKids)
        let asked = kidsRequests(transport).count
        await model.showKids(.movie)
        XCTAssertEqual(kidsRequests(transport).count, asked, "no kids request with Hide off")

        transport.respond = respond(hiding: true)
        await model.profileChanged(profile(2, hiding: true))
        XCTAssertNil(model.catalog.item(60), "hidden again until the pill asks")
        XCTAssertTrue(model.hidingKids)
    }

    func testAnotherProfilesChangeIsNotThisCatalogs() async {
        let transport = serve(hiding: false)
        let model = model(transport, hiding: false)
        await model.load()
        let before = transport.queries(.get, "/items").count
        await model.profileChanged(profile(7, hiding: true))
        XCTAssertFalse(model.hidingKids)
        XCTAssertEqual(transport.queries(.get, "/items").count, before)
    }
}
