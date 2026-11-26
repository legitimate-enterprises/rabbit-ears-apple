import RabbitEarsAPI
import XCTest

@testable import RabbitEarsKit

@MainActor
final class SelectionTests: XCTestCase {
    func testClickTogglesShiftClickTakesTheRangeAndSelectAllTakesEveryOne() {
        let selection = Selection()
        let order: [Int64] = [5, 4, 3, 2, 1]
        selection.begin()
        selection.toggle(4)
        selection.extend(to: 2, in: order)
        XCTAssertEqual(selection.ordered(order), [4, 3, 2])
        selection.toggle(3)
        XCTAssertEqual(selection.ordered(order), [4, 2])
        selection.extend(to: 5, in: order)
        XCTAssertEqual(selection.ordered(order), [5, 4, 3, 2])
        selection.selectAll(order)
        XCTAssertEqual(selection.count, 5)
        selection.end()
        XCTAssertFalse(selection.active)
        XCTAssertEqual(selection.count, 0)
    }

    func testATapOrderIsKeptForAddingInThatOrder() {
        let selection = Selection()
        selection.toggle(3)
        selection.toggle(1)
        selection.toggle(2)
        selection.toggle(3)
        XCTAssertEqual(selection.inPickOrder, [1, 2])
    }

    func testNothingFromYouTubeGoesInAPlaylistAndMusicIsNeverWatched() {
        XCTAssertNil(SelectKind.channel.playlistKind)
        XCTAssertNil(SelectKind.video.playlistKind)
        XCTAssertEqual(SelectKind.show.playlistKind, .tv)
        XCTAssertEqual(SelectKind.song.playlistKind, .music)
        XCTAssertFalse(SelectKind.album.watches)
        XCTAssertFalse(SelectKind.video.kidsContent)
    }

    func testAShiftClickWithNoAnchorIsAClick() {
        let selection = Selection()
        selection.begin()
        selection.extend(to: 2, in: [1, 2, 3])
        XCTAssertEqual(selection.ordered([1, 2, 3]), [2])
    }
}

@MainActor
final class BulkActionTests: XCTestCase {
    private let transport = RoutingTransport()

    private func catalogModel() async -> CatalogModel {
        let items = [
            "movie": [Fixtures.item(20, "movie", "Dune")],
            "show": [Fixtures.item(30, "show", "Andor")],
            "season": [Fixtures.item(31, "season", "Andor", parent: 30, season: 1)],
            "episode": [
                Fixtures.item(32, "episode", "Andor", parent: 31, episode: 1),
                Fixtures.item(33, "episode", "Andor", parent: 31, episode: 2),
            ],
        ]
        transport.respond = { @Sendable sent in
            guard sent.method == .get, sent.path == "/items" else { return nil }
            let kind = sent.query.split(separator: "&").first { $0.hasPrefix("kind=") }?.dropFirst(5) ?? ""
            return (.ok, Fixtures.page(items[String(kind)] ?? []))
        }
        transport.routes["GET /profiles/2/watch-state"] = (.ok, Fixtures.page([Fixtures.watch(32, position: 60_000)]))
        let model = CatalogModel(client: ServerEndpoint.default.client(token: "t", transport: transport), profileId: 2)
        await model.load()
        return model
    }

    func testMarkingASelectionIsOneRequestAndMarksAShowsEpisodes() async throws {
        transport.routes["PUT /profiles/2/watch-state/batch"] = (.noContent, "")
        let model = await catalogModel()
        await model.setWatched(true, for: [model.catalog.item(30)!, model.catalog.item(20)!])
        XCTAssertNil(model.error)
        XCTAssertEqual(transport.paths(.put), ["/profiles/2/watch-state/batch"])
        let body = try XCTUnwrap(transport.json(.put, "/profiles/2/watch-state/batch"))
        XCTAssertEqual(body["itemIds"] as? [Int64], [30, 20])
        XCTAssertEqual(body["watched"] as? Bool, true)
        XCTAssertEqual(model.catalog.unwatchedCount(30), 0)
        XCTAssertTrue(model.catalog.isWatched(20))
        XCTAssertFalse(model.catalog.isInProgress(32))
    }

    func testAFailedMarkChangesNothing() async {
        transport.routes["PUT /profiles/2/watch-state/batch"] = (.notFound, Fixtures.error("not_found"))
        let model = await catalogModel()
        await model.setWatched(true, for: [model.catalog.item(20)!])
        XCTAssertNotNil(model.error)
        XCTAssertFalse(model.catalog.isWatched(20))
    }

    func testKidsContentForASelectionIsOneRequest() async throws {
        transport.routes["PUT /items/kids-content/batch"] = (.noContent, "")
        let model = await catalogModel()
        await model.setKidsContent(true, for: [model.catalog.item(20)!, model.catalog.item(30)!])
        let body = try XCTUnwrap(transport.json(.put, "/items/kids-content/batch"))
        XCTAssertEqual(body["itemIds"] as? [Int64], [20, 30])
        XCTAssertEqual(body["kidsContent"] as? Bool, true)
        XCTAssertEqual(model.catalog.item(30)?.kidsContent, true)
        XCTAssertEqual(model.catalog.item(30)?.kidsContentOverride, true)
    }

    func testAddingASelectionToAPlaylistIsOneRequest() async throws {
        transport.routes["POST /profiles/2/playlists/9/entries/batch"] = (.noContent, "")
        transport.routes["GET /profiles/2/playlists/9"] = (
            .ok,
            #"{"id":9,"profileId":2,"name":"Mix","kind":"music","access":"owner","itemCount":2,"durationMs":0,"#
                + #""createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z"}"#
        )
        let model = PlaylistsModel(
            client: ServerEndpoint.default.client(token: "t", transport: transport), profileId: 2)
        let added = await model.add([101, 100], to: 9)
        XCTAssertTrue(added)
        let body = try XCTUnwrap(transport.json(.post, "/profiles/2/playlists/9/entries/batch"))
        XCTAssertEqual((body["entries"] as? [[String: Any]])?.compactMap { $0["itemId"] as? Int64 }, [101, 100])
    }

    func testYouTubeSelectionsMarkAndSetForKidsInOneRequestEach() async throws {
        transport.routes["PUT /profiles/1/watch-state/batch"] = (.noContent, "")
        transport.routes["PUT /items/kids-content/batch"] = (.noContent, "")
        let model = YouTubeModel(client: ServerEndpoint.default.client(token: "t", transport: transport), profileId: 1)
        try await model.setWatched(false, items: [60, 61])
        try await model.setForKids(true, channels: [60, 61])
        XCTAssertEqual(transport.json(.put, "/profiles/1/watch-state/batch")?["itemIds"] as? [Int64], [60, 61])
        XCTAssertEqual(transport.json(.put, "/items/kids-content/batch")?["kidsContent"] as? Bool, true)
    }
}
