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
            (.ok, Fixtures.events("c1", [#"{"kind":"playback","change":"moved","sessionId":7}"#])),
            (.ok, Fixtures.events("c2")),
            (.ok, Fixtures.events("c3", [#"{"kind":"watch_together","change":"opened"}"#, #"{"kind":"playlist"}"#])),
        ])
        XCTAssertEqual(transport.queries(.get, "/events"), ["", "after=c0", "after=c1", "after=c2", "after=c3"])
        let batches = await heard.value
        XCTAssertEqual(batches.map { $0.map(\.kind) }, [[.playback], [.watchTogether, .playlist]])
        XCTAssertEqual(batches.first?.first?.sessionId, 7)
    }

    func testAFailedPollIsAskedAgainFromTheSameCursorAfterAGrowingWait() async {
        let down = (HTTPResponse.Status.internalServerError, Fixtures.error("internal"))
        await follow([
            (.ok, Fixtures.events("c0")), down, down, down,
            (.ok, Fixtures.events("c1", [#"{"kind":"playlist"}"#])),
            down,
        ])
        XCTAssertEqual(waits, [.seconds(1), .seconds(2), .seconds(4), .seconds(1)])
        XCTAssertEqual(transport.queries(.get, "/events").filter { $0 == "after=c0" }.count, 4)
    }

    func testALockedDeviceIsNotAskedAgain() async {
        await follow([(.forbidden, Fixtures.error("device_locked")), (.ok, Fixtures.events("c0"))])
        XCTAssertEqual(transport.queries(.get, "/events").count, 1)
        XCTAssertTrue(waits.isEmpty)
    }

    func testEachCommitToTheReplicaMovesItsGroupsCount() async throws {
        let app = try SyncedApp()
        defer { app.remove() }
        let sync = try await app.synced()
        let live = app.model.live
        await app.until { live.library > 0 && live.household > 0 }
        let before = [live.library, live.watched, live.playlists, live.stations, live.household]
        XCTAssertEqual(before.filter { $0 == 0 }, [], "a new replica changes every group")
        try await sync.replica.write { try $0.watch(20, for: 1, position: 5) }
        await app.until { live.watched > before[1] }
        try await sync.replica.write {
            try $0.execute(sql: "INSERT INTO playlist(id, account_id, name) VALUES (1, 1, 'Road')")
        }
        await app.until { live.playlists > before[2] }
        try await sync.replica.write { try $0.account(9, "Sam") }
        await app.until { live.household > before[4] }
        XCTAssertEqual(
            [live.library, live.watched, live.playlists, live.stations, live.household],
            [before[0], before[1] + 1, before[2] + 1, before[3], before[4] + 1])
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
}

@MainActor
final class FollowLiveTests: XCTestCase {
    func testAFollowingCatalogReadsWhatTheReplicaCommitsAndASnapshotThatLandedFirst() async throws {
        let app = try SyncedApp { db in
            try db.account(1, "Avery")
            try db.item(20, "movie", "Dune")
        }
        defer { app.remove() }
        let sync = try await app.synced()
        let early = CatalogModel(client: try XCTUnwrap(app.model.client), replica: sync.replica, profileId: 1)
        let following = Task { await app.model.followLive(early, inView: true) }
        await app.until { early.catalog.item(20) != nil }
        XCTAssertNotNil(early.catalog.item(20), "read on following, as no commit came after it")
        try await sync.replica.write { try $0.watch(20, for: 1, position: 60_000) }
        await app.until { early.catalog.isInProgress(20) }
        XCTAssertTrue(early.catalog.isInProgress(20))
        following.cancel()
        await following.value
    }
}
