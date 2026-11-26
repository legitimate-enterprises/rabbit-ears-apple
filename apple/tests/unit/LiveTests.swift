import Foundation
import HTTPTypes
import RabbitEarsAPI
import XCTest

@testable import RabbitEarsKit

extension Fixtures {
    static func events(_ cursor: String, _ events: [String] = [], resync: Bool = false) -> String {
        #"{"cursor":"\#(cursor)","resync":\#(resync),"events":[\#(events.joined(separator: ","))]}"#
    }

    static func playing(
        _ id: Int64 = 9, device: String = "Living Room", thisDevice: Bool = false, position: Int64 = 2_472_000,
        movedTo: String? = nil
    ) -> String {
        let moved = movedTo.map { #","endedAt":"2026-11-14T20:01:00Z","movedToDeviceName":"\#($0)""# } ?? ""
        return #"{"id":\#(id),"itemId":20,"deviceId":4,"deviceName":"\#(device)","platform":"roku","#
            + #""thisDevice":\#(thisDevice),"positionMs":\#(position),"updatedAt":"2026-11-14T20:00:00Z"\#(moved)}"#
    }
}

@MainActor
final class LiveFeedTests: XCTestCase {
    var transport: RoutingTransport!
    var feed: LiveFeed!
    var client: Client!
    var waits: [Duration] = []

    override func setUp() async throws {
        transport = RoutingTransport()
        feed = LiveFeed()
        client = ServerEndpoint(userInput: "192.168.1.9")!.client(token: "t", transport: transport)
        waits = []
    }

    /// Answers each poll with the next of `answers`; once they run out the stream is gone, which ends the following.
    private func follow(_ answers: [(HTTPResponse.Status, String)]) async {
        var left = answers
        transport.respond = { sent in
            guard sent.path == "/events" else { return nil }
            return left.isEmpty ? (.notFound, Fixtures.error("not_found")) : left.removeFirst()
        }
        await feed.follow(client) { [weak self] in self?.waits.append($0) }
    }

    func testItAsksForACursorThenHoldsAPollFromEachAnswersCursor() async {
        let heard = Task { [feed] in
            var batches: [[LiveEvent]] = []
            for await batch in feed!.events() {
                batches.append(batch)
                if batches.count == 2 { break }
            }
            return batches
        }
        await Task.yield()
        await follow([
            (.ok, Fixtures.events("c0")),
            (.ok, Fixtures.events("c1", [#"{"kind":"watch_state","itemId":20}"#])),
            (.ok, Fixtures.events("c2")),
            (.ok, Fixtures.events("c3", [#"{"kind":"station","stationId":4}"#, #"{"kind":"playlist"}"#])),
        ])
        XCTAssertEqual(
            transport.queries(.get, "/events"),
            [
                "kinds=library&kinds=household", "after=c0&kinds=library&kinds=household",
                "after=c1&kinds=library&kinds=household", "after=c2&kinds=library&kinds=household",
                "after=c3&kinds=library&kinds=household",
            ])
        XCTAssertEqual([feed.watched, feed.stations, feed.playlists, feed.together], [1, 1, 1, 0])
        let batches = await heard.value
        XCTAssertEqual(batches.map { $0.map(\.kind) }, [[.watchState], [.station, .playlist]])
        XCTAssertEqual(batches.first?.first?.itemId, 20)
    }

    func testAResyncReloadsEverything() async {
        await follow([(.ok, Fixtures.events("c0")), (.ok, Fixtures.events("c1", resync: true))])
        XCTAssertEqual([feed.watched, feed.stations, feed.playlists, feed.together, feed.household], [1, 1, 1, 1, 1])
    }

    func testAFailedPollIsAskedAgainFromTheSameCursorAfterAGrowingWait() async {
        let down = (HTTPResponse.Status.internalServerError, Fixtures.error("internal"))
        await follow([
            (.ok, Fixtures.events("c0")), down, down, down,
            (.ok, Fixtures.events("c1", [#"{"kind":"playlist"}"#])),
            down,
        ])
        XCTAssertEqual(waits, [.seconds(1), .seconds(2), .seconds(4), .seconds(1)])
        XCTAssertEqual(
            transport.queries(.get, "/events").filter { $0 == "after=c0&kinds=library&kinds=household" }.count, 4)
        XCTAssertEqual(feed.playlists, 1)
    }

    func testALockedDeviceIsNotAskedAgain() async {
        await follow([(.forbidden, Fixtures.error("device_locked")), (.ok, Fixtures.events("c0"))])
        XCTAssertEqual(transport.queries(.get, "/events").count, 1)
        XCTAssertTrue(waits.isEmpty)
    }

    func testFollowingAgainOnReturnReloadsEverythingOnce() async {
        await follow([(.ok, Fixtures.events("c0"))])
        XCTAssertEqual(feed.watched, 0)
        await follow([(.ok, Fixtures.events("c5"))])
        XCTAssertEqual([feed.watched, feed.stations, feed.playlists, feed.together], [1, 1, 1, 1])
        XCTAssertEqual(
            transport.queries(.get, "/events"),
            [
                "kinds=library&kinds=household", "after=c0&kinds=library&kinds=household",
                "kinds=library&kinds=household", "after=c5&kinds=library&kinds=household",
            ])
        XCTAssertEqual(feed.household, 1)
    }

    func testAHouseholdEventIsCountedApart() async {
        await follow([(.ok, Fixtures.events("c0")), (.ok, Fixtures.events("c1", [#"{"kind":"household"}"#]))])
        XCTAssertEqual([feed.watched, feed.stations, feed.playlists, feed.together, feed.household], [0, 0, 0, 0, 1])
    }
}

@MainActor
final class HandoffTests: XCTestCase {
    var transport: RoutingTransport!
    var client: Client!
    var output: FakeOutput!
    var handoff: PlayerHandoff!
    let server = ServerEndpoint(userInput: "192.168.1.9")!
    let item = Fixtures.decode(Fixtures.item(20, "movie", "Dune"), as: Item.self)

    override func setUp() async throws {
        transport = RoutingTransport([
            "GET /playback/sessions": (.ok, Fixtures.page([Fixtures.playing(3, thisDevice: true), Fixtures.playing()]))
        ])
        client = server.client(token: "t", transport: transport)
        output = FakeOutput()
    }

    func testATitlePlayingOnAnotherDeviceIsAskedAbout() async throws {
        let found = await Handoff.elsewhere(PlayRequest(item: item), client: client)
        let there = try XCTUnwrap(found)
        XCTAssertEqual(transport.queries(.get, "/playback/sessions"), ["itemId=20"])
        XCTAssertEqual(there.id, 9)
        XCTAssertEqual(Handoff.title(there), "Playing on Living Room at 41:12")
    }

    func testNothingIsAskedOfThisDevicesOwnSessionOrARequestThatSaysWhereToStart() async {
        transport.routes["GET /playback/sessions"] = (.ok, Fixtures.page([Fixtures.playing(3, thisDevice: true)]))
        let none = await Handoff.elsewhere(PlayRequest(item: item), client: client)
        XCTAssertNil(none)
        transport.routes["GET /playback/sessions"] = (.ok, Fixtures.page([Fixtures.playing()]))
        let placed = await Handoff.elsewhere(PlayRequest(item: item, positionMs: 0), client: client)
        XCTAssertNil(placed)
        let together = WatchTogetherModel(client: client, profileId: 1, itemId: 20)
        let shared = await Handoff.elsewhere(PlayRequest(item: item, together: together), client: client)
        XCTAssertNil(shared)
        XCTAssertEqual(transport.paths(.get).count, 1)
    }

    func testACheckThatNeverAnswersLetsPlaybackStartAfterTheLimit() async {
        transport.hold = { _ in try await Task.sleep(for: .seconds(60)) }
        let none = await Handoff.elsewhere(PlayRequest(item: item), client: client, within: .milliseconds(50))
        XCTAssertNil(none)
    }

    func testAnAnswerInsideTheLimitIsStillAskedAbout() async {
        transport.hold = { _ in try await Task.sleep(for: .milliseconds(10)) }
        let found = await Handoff.elsewhere(PlayRequest(item: item), client: client, within: .seconds(30))
        XCTAssertEqual(found?.id, 9)
    }

    func testAnAnswerAfterTheLimitIsIgnored() async {
        transport.hold = { _ in try await Task.sleep(for: .milliseconds(300)) }
        let none = await Handoff.elsewhere(PlayRequest(item: item), client: client, within: .milliseconds(50))
        XCTAssertNil(none)
    }

    func testMoveHereEndsItThereAndPlaysHereWhereItWas() async throws {
        transport.routes["POST /playback/sessions/9/move"] = (.ok, Fixtures.playing(position: 2_480_000))
        let there = Fixtures.decode(Fixtures.playing(), as: PlaybackSession.self)
        let request = try await Handoff.move(there, PlayRequest(item: item, editionId: 6), client: client)
        XCTAssertEqual(request.positionMs, 2_480_000)
        XCTAssertEqual(request.editionId, 6)
        XCTAssertEqual(request.item.id, 20)
        XCTAssertNil(request.together)
    }

    func testWatchTogetherOpensOneFromTheOtherDevicesSession() async throws {
        transport.routes["POST /watch-together"] = (.created, Fixtures.together(host: (1, "Avery")))
        let there = Fixtures.decode(Fixtures.playing(), as: PlaybackSession.self)
        let request = try await Handoff.together(there, PlayRequest(item: item), client: client, profileId: 1)
        let body = try XCTUnwrap(transport.json(.post, "/watch-together"))
        XCTAssertEqual(body["itemId"] as? Int, 20)
        XCTAssertEqual(body["fromSessionId"] as? Int, 9)
        XCTAssertEqual(request.positionMs, 2_472_000)
        XCTAssertEqual(request.together?.current?.id, 5)
    }

    private func player() async -> PlayerModel {
        transport.routes["POST /playback/sessions"] = (.created, Fixtures.stream())
        transport.routes["DELETE /playback/sessions/7"] = (.noContent, "")
        let model = PlayerModel(
            client: client, endpoint: server, profileId: 1, item: item, output: output,
            capabilities: FakeCapabilities())
        await model.start(positionMs: 0)
        handoff = PlayerHandoff(player: model, client: client, profileId: 1, itemId: 20)
        return model
    }

    func testAPlayerWhoseSessionAnotherDeviceTookStopsAndSaysWhereItWent() async {
        let model = await player()
        transport.routes["GET /playback/sessions/7"] = (.ok, Fixtures.playing(7, movedTo: "Kitchen iPad"))
        let other = #"{"kind":"playback","change":"moved","sessionId":8,"itemId":20}"#
        await handoff.heard([Fixtures.decode(other, as: LiveEvent.self)])
        XCTAssertNil(handoff.movedTo)
        let mine = #"{"kind":"playback","change":"moved","sessionId":7,"itemId":20}"#
        await handoff.heard([Fixtures.decode(mine, as: LiveEvent.self)])
        XCTAssertEqual(handoff.movedTo, "Kitchen iPad")
        XCTAssertNil(model.stream)
        await model.stop()
        XCTAssertFalse(transport.paths(.delete).contains("/playback/sessions/7"), "the server already ended it")
    }

    func testAPlayerJoinsTheWatchTogetherAnotherDeviceOpenedFromItsSession() async throws {
        _ = await player()
        output.positionMs = 61_000
        let joined = Fixtures.together(status: "joined", host: (1, "Avery"), joined: true)
        transport.routes["POST /watch-together/5/join"] = (.ok, joined)
        transport.routes["PUT /watch-together/5/state"] = (.ok, joined)
        let other = #"{"kind":"watch_together","change":"opened","watchTogetherId":4,"itemId":20}"#
        await handoff.heard([Fixtures.decode(other, as: LiveEvent.self)])
        XCTAssertNil(handoff.asked)
        let mine = #"{"kind":"watch_together","change":"opened","watchTogetherId":5,"itemId":20,"sessionId":7}"#
        await handoff.heard([Fixtures.decode(mine, as: LiveEvent.self)])
        XCTAssertEqual(handoff.asked?.current?.id, 5)
        let state = try XCTUnwrap(transport.json(.put, "/watch-together/5/state"))
        XCTAssertEqual(state["playing"] as? Bool, true)
        XCTAssertEqual(state["positionMs"] as? Int, 61_000)
    }

    func testOneProfileOnTwoDevicesIsInOnlyWhatThisDeviceJoinedAndNamesTheOtherDevice() async {
        let there =
            #"{"accountId":1,"name":"Avery","role":"host","deviceName":"Living Room","platform":"roku","#
            + #""present":true,"joinedAt":"2026-11-14T20:00:00Z","thisDevice":false}"#
        let here = there.replacingOccurrences(of: "Living Room", with: "Mac").replacingOccurrences(
            of: #""thisDevice":false"#, with: #""thisDevice":true"#
        ).replacingOccurrences(of: "host", with: "guest")
        func state(_ members: [String], _ status: String) -> String {
            Fixtures.together(status: status).replacingOccurrences(
                of: Fixtures.member(3, "Heidi", role: "host"), with: members.joined(separator: ","))
        }
        let model = WatchTogetherModel(client: client, profileId: 1, itemId: 20)
        transport.routes["GET /watch-together"] = (.ok, Fixtures.page([state([there], "waiting")]))
        await model.refresh()
        XCTAssertNil(model.current)
        XCTAssertEqual(model.joinLabel(at: Date())?.hasPrefix("Join Living Room"), true)
        transport.routes["GET /watch-together"] = (.ok, Fixtures.page([state([there, here], "joined")]))
        await model.refresh()
        XCTAssertEqual(model.current?.id, 5)
        XCTAssertEqual(model.partnerName, "Living Room")
    }

    func testTheCatalogTakesTheWatchStateAnEventNamesAndForgetsOneTheServerDropped() async {
        let state =
            #"{"itemId":20,"positionMs":61000,"watched":false,"playCount":0,"updatedAt":"2026-11-14T20:00:00Z"}"#
        transport.routes["GET /profiles/1/watch-state/20"] = (.ok, state)
        let catalog = CatalogModel(client: client, profileId: 1)
        transport.routes["GET /items"] = (.ok, Fixtures.page([Fixtures.item(20, "movie", "Dune")]))
        transport.routes["GET /profiles/1/watch-state"] = (.ok, Fixtures.page([]))
        await catalog.load()
        XCTAssertFalse(catalog.catalog.isInProgress(20))
        await catalog.heard([Fixtures.decode(#"{"kind":"watch_state","itemId":20}"#, as: LiveEvent.self)])
        XCTAssertTrue(catalog.catalog.isInProgress(20))
        transport.routes["GET /profiles/1/watch-state/20"] = nil
        let ended = #"{"kind":"playback","change":"ended","itemId":20}"#
        await catalog.heard([Fixtures.decode(ended, as: LiveEvent.self)])
        XCTAssertFalse(catalog.catalog.isInProgress(20))
    }

    func testAFinishedScanReloadsTheCatalog() async {
        transport.routes["GET /items"] = (.ok, Fixtures.page([Fixtures.item(20, "movie", "Dune")]))
        transport.routes["GET /profiles/1/watch-state"] = (.ok, Fixtures.page([]))
        let catalog = CatalogModel(client: client, profileId: 1)
        await catalog.heard([Fixtures.decode(#"{"kind":"library","libraryId":2}"#, as: LiveEvent.self)])
        XCTAssertNotNil(catalog.catalog.item(20))
    }
}

@MainActor
final class FollowLiveTests: XCTestCase {
    func testFollowingAgainReloadsTheCatalog() async throws {
        let transport = RoutingTransport([
            "POST /auth/sign-in": (.created, Fixtures.signedIn), "GET /me": (.ok, Fixtures.me),
        ])
        let model = AppModel(store: MemoryCredentialStore(), deviceName: "Test Mac", transport: transport)
        try await model.signIn(server: "rabbit.local", email: "a@example.test", password: "x")
        var polls = 0
        transport.respond = { sent in
            guard sent.path == "/events" else { return nil }
            polls += 1
            return [2, 10].contains(polls) ? (.notFound, Fixtures.error("not_found")) : (.ok, Fixtures.events("c"))
        }
        let catalog = CatalogModel(client: try XCTUnwrap(model.client), profileId: 1)
        func loads() -> Int { transport.paths(.get).filter { $0 == "/items" }.count }
        await model.followLive(catalog, inView: true)
        XCTAssertEqual(loads(), 0)
        await model.followLive(catalog, inView: true)
        XCTAssertGreaterThan(loads(), 0, "following again loads everything once")
    }
}
