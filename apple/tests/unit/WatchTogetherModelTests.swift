import Foundation
import RabbitEarsAPI
import XCTest

@testable import RabbitEarsKit

extension Fixtures {
    static func member(_ id: Int64, _ name: String, role: String) -> String {
        #"{"accountId":\#(id),"name":"\#(name)","role":"\#(role)","deviceName":"Living room","#
            + #""platform":"tvos","present":true,"joinedAt":"2026-11-14T20:00:00Z"}"#
    }

    /// Heidi (3) hosts; Avery (1), the signed-in adult, is the guest once joined. The
    /// server's clock matches the tests' and the state is in effect from now.
    static func together(
        _ id: Int64 = 5, status: String = "waiting", host: (Int64, String) = (3, "Heidi"), joined: Bool = false,
        playing: Bool = false, position: Int64 = 0, version: Int = 1, msLeft: Int64 = 252_000,
        pausedBy: (Int64, String)? = nil, effectiveAt: Int64 = 1_000_000_000, serverTime: Int64 = 1_000_000_000
    ) -> String {
        var members = [member(host.0, host.1, role: "host")]
        if joined { members.append(member(host.0 == 1 ? 3 : 1, host.0 == 1 ? "Heidi" : "Avery", role: "guest")) }
        let paused = pausedBy.map { #","pausedById":\#($0.0),"pausedByName":"\#($0.1)""# } ?? ""
        return #"{"id":\#(id),"itemId":20,"status":"\#(status)","members":[\#(members.joined(separator: ","))],"#
            + #""joinBy":"2026-11-14T20:05:00Z","joinMsLeft":\#(msLeft),"playing":\#(playing),"#
            + #""positionMs":\#(position),"version":\#(version),"serverTime":"2026-11-14T20:00:48Z","#
            + #""openedAt":"2026-11-14T20:00:00Z","serverTimeMs":\#(serverTime),"effectiveAtMs":\#(effectiveAt),"#
            + #""effectivePositionMs":\#(position)\#(paused)}"#
    }
}

@MainActor
final class WatchTogetherModelTests: XCTestCase {
    var transport: RoutingTransport!
    var model: WatchTogetherModel!
    var output: FakeOutput!
    var clock = Date(timeIntervalSince1970: 1_000_000)

    override func setUp() async throws {
        transport = RoutingTransport()
        output = FakeOutput()
        model = WatchTogetherModel(
            client: ServerEndpoint(userInput: "192.168.1.9")!.client(token: "t", transport: transport),
            profileId: 1, itemId: 20, now: { [unowned self] in clock })
    }

    func testAnotherAdultsWaitingOneOffersJoinWithACountdown() async {
        transport.routes["GET /watch-together"] = (.ok, Fixtures.page([Fixtures.together()]))
        await model.refresh()
        XCTAssertEqual(transport.queries(.get, "/watch-together"), ["itemId=20"])
        XCTAssertNil(model.current)
        XCTAssertEqual(model.joinLabel(at: clock), "Join Heidi · 4:12")
        XCTAssertEqual(model.joinLabel(at: clock.addingTimeInterval(12)), "Join Heidi · 4:00")
        XCTAssertNil(model.joinLabel(at: clock.addingTimeInterval(300)))
        XCTAssertNil(model.waitingLabel(at: clock))
    }

    func testOpeningWaitsForSomeoneToJoin() async {
        transport.routes["POST /watch-together"] = (.created, Fixtures.together(host: (1, "Avery"), msLeft: 272_000))
        await model.open()
        XCTAssertEqual(transport.json(.post, "/watch-together")?["itemId"] as? Int, 20)
        XCTAssertEqual(model.current?.id, 5)
        XCTAssertEqual(model.waitingLabel(at: clock), "Waiting for someone to join · 4:32")
        XCTAssertNil(model.joinLabel(at: clock))
        XCTAssertNil(model.partnerName)
    }

    func testMyOwnOpenOneIsCurrentAfterARefresh() async {
        transport.routes["GET /watch-together"] = (
            .ok, Fixtures.page([Fixtures.together(9, host: (1, "Avery")), Fixtures.together(5)])
        )
        await model.refresh()
        XCTAssertEqual(model.current?.id, 9)
        XCTAssertNil(model.joinLabel(at: clock))
    }

    func testJoiningMakesItCurrentAndNamesThePartner() async {
        transport.routes["GET /watch-together"] = (.ok, Fixtures.page([Fixtures.together()]))
        transport.routes["POST /watch-together/5/join"] = (.ok, Fixtures.together(status: "joined", joined: true))
        await model.refresh()
        await model.join()
        XCTAssertEqual(transport.paths(.post), ["/watch-together/5/join"])
        XCTAssertEqual(model.current?.status, .joined)
        XCTAssertEqual(model.partnerName, "Heidi")
        XCTAssertNil(model.joinLabel(at: clock))
    }

    func testAMemberOutsideThePlayerStartsItWhenPlayingTurnsTrue() async {
        var started: [Int64] = []
        model.onStart = { started.append($0) }
        transport.routes["POST /watch-together"] = (.created, Fixtures.together(host: (1, "Avery")))
        await model.open()
        transport.routes["GET /watch-together/5"] = (
            .ok, Fixtures.together(status: "joined", host: (1, "Avery"), joined: true, version: 2)
        )
        await model.poll()
        XCTAssertEqual(started, [])
        transport.routes["GET /watch-together/5"] = (
            .ok,
            Fixtures.together(
                status: "joined", host: (1, "Avery"), joined: true, playing: true, position: 90_000, version: 3)
        )
        await model.poll()
        await model.poll()
        XCTAssertEqual(started, [90_000])
    }

    func testPollsApplyPlayingAndSeekOnlyWhenMoreThanHalfASecondOff() async {
        await joined()
        model.attach(output)
        output.isPaused = true
        output.positionMs = 60_300
        transport.routes["GET /watch-together/5"] = (
            .ok, Fixtures.together(status: "joined", joined: true, playing: true, position: 60_000, version: 3)
        )
        await model.poll()
        XCTAssertFalse(output.isPaused)
        XCTAssertEqual(output.seeks, [])

        transport.routes["GET /watch-together/5"] = (
            .ok, Fixtures.together(status: "joined", joined: true, playing: true, position: 65_000, version: 3)
        )
        output.positionMs = 61_500
        await model.poll()
        XCTAssertEqual(output.seeks, [65_000])
        XCTAssertEqual(model.sharedPositionMs(at: clock.addingTimeInterval(2)), 67_000, "it runs on while playing")

        transport.routes["GET /watch-together/5"] = (
            .ok,
            Fixtures.together(
                status: "joined", joined: true, position: 70_000, version: 4, pausedBy: (3, "Heidi"))
        )
        output.positionMs = 69_800
        await model.poll()
        XCTAssertTrue(output.isPaused)
        XCTAssertEqual(output.seeks, [65_000])
        XCTAssertEqual(model.pausedNotice, "Heidi paused")
    }

    func testABufferingPlayerIsNotSeekedAgainUntilItPlays() async {
        await joined()
        model.attach(output)
        output.isBuffering = true
        output.positionMs = 10_000
        transport.routes["GET /watch-together/5"] = (
            .ok, Fixtures.together(status: "joined", joined: true, playing: true, position: 65_000, version: 3)
        )
        await model.poll()
        XCTAssertEqual(output.seeks, [])
        output.isBuffering = false
        await model.poll()
        XCTAssertEqual(output.seeks, [65_000])
    }

    func testAnAnswerOlderThanOneAlreadyAppliedIsIgnored() async {
        await joined()
        model.attach(output)
        output.isPaused = false
        transport.routes["PUT /watch-together/5/state"] = (
            .ok, Fixtures.together(status: "joined", joined: true, position: 10_000, version: 6, pausedBy: (1, "Avery"))
        )
        await model.pause()
        XCTAssertTrue(output.isPaused)
        XCTAssertNil(model.pausedNotice, "no notice for one's own pause")
        transport.routes["GET /watch-together/5"] = (
            .ok, Fixtures.together(status: "joined", joined: true, playing: true, version: 5)
        )
        await model.poll()
        XCTAssertTrue(output.isPaused)
        XCTAssertEqual(model.current?.version, 6)
    }

    func testViewerActionsSendTheStateWithThePlayersPosition() async {
        await joined()
        model.attach(output)
        output.isPaused = true
        output.positionMs = 42_000
        transport.routes["PUT /watch-together/5/state"] = (
            .ok, Fixtures.together(status: "joined", joined: true, playing: true, position: 42_000, version: 4)
        )
        await model.play()
        XCTAssertFalse(output.isPaused)
        XCTAssertEqual(transport.json(.put, "/watch-together/5/state")?["playing"] as? Bool, true)
        XCTAssertEqual(transport.json(.put, "/watch-together/5/state")?["positionMs"] as? Int, 42_000)

        transport.routes["PUT /watch-together/5/state"] = (
            .ok, Fixtures.together(status: "joined", joined: true, playing: true, position: 600_000, version: 5)
        )
        await model.seek(toMs: 600_000)
        XCTAssertEqual(output.seeks, [600_000])
        XCTAssertEqual(transport.json(.put, "/watch-together/5/state")?["positionMs"] as? Int, 600_000)
        XCTAssertEqual(transport.json(.put, "/watch-together/5/state")?["playing"] as? Bool, true)
    }

    func testLeavingEndsItAndTheOtherSidePlaysOnAlone() async {
        await joined()
        model.attach(output)
        output.isPaused = false
        transport.routes["GET /watch-together/5"] = (
            .ok, Fixtures.together(status: "ended", joined: true, version: 9)
        )
        await model.poll()
        XCTAssertNil(model.current)
        XCTAssertFalse(output.isPaused)

        await joined()
        transport.routes["DELETE /watch-together/5"] = (.noContent, "")
        await model.leave()
        XCTAssertEqual(transport.paths(.delete), ["/watch-together/5"])
        XCTAssertNil(model.current)
    }

    func testOneLeftIsNotTakenBackByALaterRefresh() async {
        await joined()
        transport.routes["DELETE /watch-together/5"] = (.internalServerError, Fixtures.error("internal"))
        await model.leave()
        transport.routes["GET /watch-together"] = (
            .ok, Fixtures.page([Fixtures.together(status: "joined", joined: true, version: 2)])
        )
        await model.refresh()
        XCTAssertNil(model.current)
        XCTAssertNil(model.joinLabel(at: clock))
    }

    func testAPollAnsweredAfterLeavingDoesNotReopenThePlayer() async {
        await joined()
        var started: [Int64] = []
        model.onStart = { started.append($0) }
        transport.routes["DELETE /watch-together/5"] = (.noContent, "")
        let arrived = expectation(description: "the poll is in flight")
        let release = DispatchSemaphore(value: 0)
        transport.respond = { sent in
            guard sent.method == .get else { return nil }
            arrived.fulfill()
            release.wait()
            return (
                .ok, Fixtures.together(status: "joined", joined: true, playing: true, position: 90_000, version: 7)
            )
        }
        let model = model!
        let poll = Task { await model.poll() }
        await fulfillment(of: [arrived], timeout: 5)
        await model.leave()
        release.signal()
        await poll.value
        XCTAssertNil(model.current)
        XCTAssertEqual(started, [])
    }

    func testAGoneOneIsDroppedAndAForbiddenOpenShowsTheMessage() async {
        await joined()
        transport.routes["GET /watch-together/5"] = (.notFound, Fixtures.error("not_found"))
        await model.poll()
        XCTAssertNil(model.current)

        transport.routes["POST /watch-together"] = (
            .forbidden, Fixtures.error("forbidden", "Kids can't watch together.")
        )
        await model.open()
        XCTAssertNil(model.current)
        XCTAssertEqual(model.error, "Kids can't watch together.")
    }

    func testAPlayAheadStartsThePlayerAtItsInstant() async {
        await joined()
        model.attach(output)
        output.isPaused = true
        transport.routes["GET /watch-together/5"] = (
            .ok,
            Fixtures.together(
                status: "joined", joined: true, playing: true, position: 30_000, version: 3,
                effectiveAt: 1_000_001_500)
        )
        await model.poll()
        XCTAssertTrue(output.isPaused, "nothing before the instant")
        XCTAssertEqual(output.scheduled.map(\.ms), [30_000])
        XCTAssertEqual(output.scheduled.first?.after ?? 0, 1.5, accuracy: 0.001)
        XCTAssertEqual(model.sharedPositionMs(at: clock), 30_000, "held until it starts")
    }

    func testAPauseAheadAppliesAtItsInstant() async {
        await joined()
        model.attach(output)
        output.isPaused = false
        output.positionMs = 5_000
        transport.routes["GET /watch-together/5"] = (
            .ok,
            Fixtures.together(
                status: "joined", joined: true, position: 5_000, version: 3, effectiveAt: 1_000_000_100)
        )
        await model.poll()
        XCTAssertFalse(output.isPaused)
        try? await Task.sleep(for: .milliseconds(400))
        XCTAssertTrue(output.isPaused)
        XCTAssertEqual(output.seeks, [])
    }

    func testTheClockComesFromTheQuickestQuickPollAndHeldPollsWaitForTheNextVersion() async {
        await joined()
        transport.routes["GET /watch-together/5"] = (
            .ok, Fixtures.together(status: "joined", joined: true, version: 2, serverTime: 1_000_060_000)
        )
        await model.poll()
        XCTAssertEqual(model.offsetMs, 60_000)
        transport.routes["GET /watch-together/5"] = (
            .ok, Fixtures.together(status: "joined", joined: true, version: 2, serverTime: 1_000_090_000)
        )
        await model.poll(held: true)
        XCTAssertEqual(model.offsetMs, 60_000, "a held answer says nothing of the clock")
        XCTAssertEqual(transport.queries(.get, "/watch-together/5"), ["", "after=2&rttMs=0"])
    }

    func testPlayTogetherOnDetailsPlaysForBothAndOpensThePlayer() async {
        await joined()
        var started: [Int64] = []
        model.onStart = { started.append($0) }
        transport.routes["PUT /watch-together/5/state"] = (
            .ok,
            Fixtures.together(
                status: "joined", joined: true, playing: true, position: 0, version: 3, effectiveAt: 1_000_001_000)
        )
        await model.playTogether()
        XCTAssertEqual(transport.json(.put, "/watch-together/5/state")?["playing"] as? Bool, true)
        XCTAssertEqual(transport.json(.put, "/watch-together/5/state")?["positionMs"] as? Int, 0)
        XCTAssertEqual(started, [0])
    }

    private func joined() async {
        transport.routes["POST /watch-together"] = (
            .created, Fixtures.together(status: "joined", joined: true, version: 2)
        )
        await model.open()
    }
}

/// Who gets a Watch together: the active profile, whichever kind it is.
@MainActor
final class WatchTogetherProfileTests: XCTestCase {
    func testAKidWatchesTogetherAsAnAdultDoes() async throws {
        let waiting = Fixtures.together()
        let joined = waiting.replacingOccurrences(of: "waiting", with: "joined").replacingOccurrences(
            of: "]", with: ",\(Fixtures.member(2, "Robin", role: "guest"))]")
        let transport = RoutingTransport([
            "POST /auth/sign-in": (.created, Fixtures.signedIn),
            "POST /profiles/2/unlock": (.noContent, ""),
            "GET /watch-together": (.ok, Fixtures.page([waiting])),
            "POST /watch-together/5/join": (.ok, joined),
        ])
        let app = AppModel(store: MemoryCredentialStore(), deviceName: "Test Mac", transport: transport)
        try await app.signIn(server: "rabbit.local", email: "a@example.test", password: "x")
        XCTAssertNil(app.watchTogether(itemId: 20), "nobody is watching yet")
        try await app.choose(XCTUnwrap(app.profiles.last), pin: "1234")
        XCTAssertEqual(app.activeProfile?.kind, .kid)

        let together = try XCTUnwrap(app.watchTogether(itemId: 20))
        await together.refresh()
        XCTAssertEqual(together.invite?.id, 5)
        await together.join()
        XCTAssertTrue(together.inSync)
        XCTAssertEqual(together.partnerName, "Heidi")
    }
}
