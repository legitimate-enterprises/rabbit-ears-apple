import Foundation
import RabbitEarsAPI
import XCTest

@testable import RabbitEarsKit

@MainActor
final class UpNextModelTests: XCTestCase {
    var transport: RoutingTransport!
    var client: Client!
    let avery = Fixtures.decode(Fixtures.adult, as: Account.self)

    override func setUp() async throws {
        transport = RoutingTransport()
        client = ServerEndpoint(userInput: "192.168.1.9")!.client(token: "t", transport: transport)
    }

    private func answer(_ item: Int64, _ json: String) {
        transport.routes["GET /profiles/1/up-next/\(item)"] = (.ok, json)
    }

    func testTheNextEpisodePlaysFromTheStartInTheSamePlayer() async throws {
        let ended = PlayRequest(item: Fixtures.decode(Fixtures.item(21, "episode", "Pilot"), as: Item.self))
        answer(
            21,
            #"{"itemId":22,"kind":"episode","title":"Alpha · S1 E2 · Second","item":"#
                + Fixtures.item(22, "episode", "Second") + "}")
        let loaded = await UpNextModel.load(after: ended, client: client, profile: avery)
        let next = try XCTUnwrap(loaded)
        XCTAssertEqual(next.title, "Alpha · S1 E2 · Second")
        XCTAssertEqual(next.request.item.id, 22)
        XCTAssertEqual(next.request.positionMs, 0)
        XCTAssertEqual(next.request.id, ended.id)
        XCTAssertTrue(next.autoplay, "on unless the profile turned it off")
        XCTAssertEqual(transport.queries(.get, "/profiles/1/up-next/21"), [""])
    }

    func testAPlaylistAsksFromItsRowAndPlaysTheRowAnswered() async throws {
        let rows = [20, 21, 22].map {
            Fixtures.decode(Fixtures.row(entry: $0, item: $0, kind: "movie"), as: PlayOrderRow.self)
        }
        let queue = try XCTUnwrap(VideoQueue(rows, start: 0, playlistId: 3))
        answer(
            20,
            #"{"itemId":22,"kind":"movie","title":"T22","index":2,"item":"# + Fixtures.item(22, "movie", "T22") + "}")
        let loaded = await UpNextModel.load(
            after: PlayRequest(item: queue.current, queue: queue), client: client, profile: avery)
        let next = try XCTUnwrap(loaded)
        XCTAssertEqual(transport.queries(.get, "/profiles/1/up-next/20"), ["playlistId=3&index=0"])
        XCTAssertEqual(next.request.queue?.index, 2)
        XCTAssertEqual(next.request.item.id, 22)
    }

    func testAVideoPlaysAsTheVideo() async throws {
        let ended = PlayRequest(item: Fixtures.decode(Fixtures.item(40, "movie", "Old"), as: Item.self))
        answer(
            40,
            #"{"itemId":41,"kind":"video","title":"New","video":{"id":41,"libraryId":1,"channelId":5,"#
                + #""channelTitle":"Shop","title":"New","addedAt":"2026-01-01T00:00:00Z","#
                + #""positionMs":0,"watched":false}}"#
        )
        let loaded = await UpNextModel.load(after: ended, client: client, profile: avery)
        let next = try XCTUnwrap(loaded)
        XCTAssertEqual(next.request.item.id, 41)
        XCTAssertEqual(next.title, "New")
    }

    func testNothingNextIsNil() async {
        transport.routes["GET /profiles/1/up-next/21"] = (.noContent, "")
        let ended = PlayRequest(item: Fixtures.decode(Fixtures.item(21, "episode", "Pilot"), as: Item.self))
        let next = await UpNextModel.load(after: ended, client: client, profile: avery)
        XCTAssertNil(next)
    }

    func testTheCountdownRunsOnlyWithAutoplayOn() async {
        let request = PlayRequest(item: Fixtures.decode(Fixtures.item(22, "movie", "T22"), as: Item.self))
        let on = UpNextModel(title: "T22", request: request, autoplay: true)
        var ticks = 0
        let played = await on.countdown { ticks += 1 }
        XCTAssertTrue(played)
        XCTAssertEqual(ticks, UpNextModel.countdownSeconds)
        XCTAssertEqual(on.secondsLeft, 0)

        let off = UpNextModel(title: "T22", request: request, autoplay: false)
        let waited = await off.countdown { XCTFail("no countdown with Autoplay off") }
        XCTAssertFalse(waited)
        XCTAssertNil(off.secondsLeft)

        let cancelled = await on.countdown { throw CancellationError() }
        XCTAssertFalse(cancelled)
    }

    func testTheCardsCheckboxSavesAutoplayForTheProfile() async throws {
        let store = MemoryCredentialStore()
        transport.routes = [
            "POST /auth/sign-in": (.created, Fixtures.signedIn),
            "GET /me": (.ok, Fixtures.me),
            "POST /profiles/1/unlock": (.noContent, ""),
            "PUT /profiles/1/preferences": (.ok, Fixtures.adult),
        ]
        let model = AppModel(store: store, deviceName: "Test Mac", transport: transport)
        try await model.signIn(server: "rabbit.local", email: "a@example.test", password: "x")
        try await model.choose(try XCTUnwrap(model.profiles.first))
        let request = PlayRequest(item: Fixtures.decode(Fixtures.item(22, "movie", "T22"), as: Item.self))
        let next = UpNextModel(title: "T22", request: request, autoplay: true)
        await next.setAutoplay(false, model: model)
        XCTAssertFalse(next.autoplay)
        XCTAssertEqual(transport.json(.put, "/profiles/1/preferences")?["autoplay"] as? Bool, false)
    }
}
