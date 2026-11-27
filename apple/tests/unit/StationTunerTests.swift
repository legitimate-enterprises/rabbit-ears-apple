import Foundation
import HTTPTypes
import RabbitEarsAPI
import XCTest

@testable import RabbitEarsKit

@MainActor
final class StationTunerTests: XCTestCase {
    var transport: RoutingTransport!
    var output: FakeOutput!
    var capabilities: FakeCapabilities!
    var player: PlayerModel!
    var tuner: StationTuner!
    var replica: Replica!
    var slept: [Date] = []
    /// The first wait passes at once; later ones, or every one when false, hold until the test ends.
    var wakesAtOnce = true
    /// Answers to the station's playback asks, first to last; the last repeats.
    /// Read off the main actor while each test awaits the request.
    nonisolated(unsafe) var answers: [(HTTPResponse.Status, String)] = []
    let server = ServerEndpoint(userInput: "192.168.1.9")!

    static let offAir = #"{"code":"off_air","message":"nothing is on","resumesAt":"2026-11-15T16:00:00Z"}"#
    nonisolated static let ask = "/stations/\(UID.n(5))/playback"

    override func setUp() async throws {
        transport = RoutingTransport([
            "DELETE /playback/sessions/\(UID.n(7))": (.noContent, ""),
            "DELETE /playback/sessions/\(UID.n(8))": (.noContent, ""),
            "PUT /playback/sessions/\(UID.n(7))/position": (.noContent, ""),
        ])
        transport.respond = { [unowned self] sent in
            guard sent.method == .post, sent.path == Self.ask else { return nil }
            return self.answers.count > 1 ? self.answers.removeFirst() : self.answers[0]
        }
        output = FakeOutput()
        capabilities = FakeCapabilities()
        let client = server.client(token: "t", transport: transport)
        replica = try tunerReplica()
        tuner = stationTuner(client: client, replica: replica, station: Fixtures.decode(Fixtures.bigScreen)) {
            [unowned self] date in
            self.slept.append(date)
            if !self.wakesAtOnce || self.slept.count > 1 { try await Task.sleep(for: .seconds(3600)) }
        }
        player = PlayerModel(
            client: client, endpoint: server, profileId: 1, item: nil, output: output, capabilities: capabilities)
    }

    override func tearDown() async throws {
        tuner.cancel()
    }

    private func tuned(session: UID = 7, position: Int64 = 4_328_000) -> (HTTPResponse.Status, String) {
        let onAir = Fixtures.onAir("on_air", now: Fixtures.lantern, position: position, next: Fixtures.salt)
        return (.created, #"{"stream":\#(Fixtures.stream(session: session, position: position)),"onAir":\#(onAir)}"#)
    }

    private var asks: Int { transport.paths(.post).filter { $0 == Self.ask }.count }

    /// Waits for work a wake started on its own task.
    private func until(_ done: () -> Bool) async {
        for _ in 0..<200 where !done() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    func testTuningInSendsTheSnapshotAndPlaysAtTheLivePosition() async throws {
        wakesAtOnce = false
        answers = [tuned()]
        await player.tune(tuner)
        let body = try XCTUnwrap(transport.json(.post, Self.ask))
        let snapshot = try XCTUnwrap(body["snapshot"] as? [String: Any])
        XCTAssertEqual(Set(snapshot.keys), ["decoder", "display", "audioRoute", "network"])
        XCTAssertEqual(output.loaded.first?.1, 4328)
        XCTAssertFalse(tuner.offAir)
        XCTAssertEqual(tuner.station.onAir.now?.itemId, 20)
        XCTAssertEqual(tuner.wakeAt, ISO8601DateFormatter().date(from: "2026-11-15T15:52:00Z"))
    }

    func testOffAirWaitsForResumesAtThenAsksAgain() async throws {
        // The wait holds, so the state between programs is read before the wake.
        wakesAtOnce = false
        answers = [(.conflict, Self.offAir), tuned(session: 8)]
        await player.tune(tuner)
        XCTAssertTrue(tuner.offAir)
        XCTAssertNil(player.error)
        XCTAssertTrue(output.loaded.isEmpty)
        XCTAssertEqual(
            tuner.station.onAir.status, .betweenPrograms, "the station is read from the replica for its next")
        let resumes = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-15T16:00:00Z"))
        XCTAssertEqual(tuner.wakeAt, resumes)
        await until { slept.count == 1 }
        XCTAssertEqual(slept.first, resumes)
        await tuner.onWake?()
        await until { asks == 2 && !output.loaded.isEmpty }
        XCTAssertEqual(asks, 2)
        XCTAssertFalse(tuner.offAir)
        XCTAssertEqual(player.stream?.sessionId, 8)
    }

    func testTheProgramsEndEndsTheSessionAndAsksAgain() async {
        answers = [tuned(), (.conflict, Self.offAir)]
        await player.tune(tuner)
        await until { tuner.offAir }
        XCTAssertEqual(asks, 2)
        XCTAssertEqual(slept.first, ISO8601DateFormatter().date(from: "2026-11-15T15:52:00Z"))
        XCTAssertEqual(transport.paths(.delete), ["/playback/sessions/\(UID.n(7))"])
        XCTAssertTrue(tuner.offAir)
        XCTAssertNil(player.stream)
    }

    /// The server says the program ends at a time this device's clock has
    /// already passed, as when the device runs ahead of the server.
    func testAClockAheadOfTheServersDoesNotAskInATightLoop() async {
        answers = [tuned()]
        let real = StationTuner(
            client: server.client(token: "t", transport: transport), replica: replica, profileId: 1,
            station: Fixtures.decode(Fixtures.bigScreen))
        await player.tune(real)
        try? await Task.sleep(for: .milliseconds(300))
        real.cancel()
        XCTAssertEqual(asks, 1)
    }

    func testACapabilityChangeAsksForPlaybackAgain() async {
        wakesAtOnce = false
        answers = [tuned(), tuned(session: 8)]
        await player.tune(tuner)
        capabilities.current.route = RouteFacts(channels: 6)
        await player.capabilitiesChanged(.audioRoute)
        XCTAssertEqual(asks, 2)
        XCTAssertEqual(transport.paths(.delete), ["/playback/sessions/\(UID.n(7))"], "the session it leaves is ended")
        XCTAssertFalse(transport.paths(.put).contains("/playback/sessions/\(UID.n(7))/audio-route"))
    }

    /// Starting a stream raises route and screen notifications of its own;
    /// asking again for each opened sessions in a loop.
    func testANotificationThatChangesNothingAsksNothing() async {
        wakesAtOnce = false
        answers = [tuned()]
        await player.tune(tuner)
        for group in [CapabilityGroup.display, .audioRoute, .network] { await player.capabilitiesChanged(group) }
        XCTAssertEqual(asks, 1)
        XCTAssertTrue(transport.paths(.delete).isEmpty)
    }

    /// Every caller at once, as a view's appearance, the program's end and
    /// a wake can be, makes one tune-in and one session.
    func testTuningInWhileATuneIsInFlightStartsNoSecondSession() async {
        wakesAtOnce = false
        answers = [tuned()]
        let (player, tuner) = (player!, tuner!)
        let calls = [
            Task { await player.tune(tuner) }, Task { await player.tune(tuner) },
            Task { await player.programEnded(tuner) },
        ]
        for call in calls { await call.value }
        XCTAssertEqual(asks, 1)
        XCTAssertEqual(output.loaded.count, 1)
        XCTAssertTrue(transport.paths(.delete).isEmpty)
    }

    /// A change heard while the session starts asks once more when it has,
    /// ending the one it replaces.
    func testAChangeWhileTuningInAsksOnceMoreAfter() async {
        wakesAtOnce = false
        answers = [tuned(), tuned(session: 8)]
        capabilities.afterNextRead = { [unowned self] in capabilities.current.route = RouteFacts(channels: 6) }
        await player.tune(tuner)
        XCTAssertEqual(asks, 2)
        XCTAssertEqual(transport.paths(.delete), ["/playback/sessions/\(UID.n(7))"])
        XCTAssertEqual(player.stream?.sessionId, 8)
    }

    /// The stream ran out before the program's scheduled end, as a file
    /// shorter than its runtime does: asking now would join the same
    /// program past the stream's end, over and over. The wake at its end asks.
    func testAStreamEndingBeforeItsProgramWaitsForTheWake() async {
        wakesAtOnce = false
        let ends = ISO8601DateFormatter().string(from: Date().addingTimeInterval(600))
        let program = Fixtures.program(20, "The Lantern Keeper", ends: ends)
        let onAir = Fixtures.onAir("on_air", now: program, position: 60_000)
        answers = [(.created, #"{"stream":\#(Fixtures.stream(session: 7, position: 60_000)),"onAir":\#(onAir)}"#)]
        await player.tune(tuner)
        await player.programEnded(tuner)
        XCTAssertEqual(asks, 1)
        XCTAssertTrue(transport.paths(.delete).isEmpty)
    }

    func testAStreamEndingAtItsProgramsEndAsksAgain() async {
        wakesAtOnce = false
        answers = [tuned(), (.conflict, Self.offAir)]
        await player.tune(tuner)
        await player.programEnded(tuner)
        XCTAssertEqual(asks, 2)
        XCTAssertTrue(tuner.offAir)
    }

    private func live(_ onAir: String) -> (HTTPResponse.Status, String) {
        let stream = Fixtures.stream(url: "/api/v2/channels/k1/live.m3u8", verdict: "remux", extra: #","live":true"#)
        return (.created, #"{"stream":\#(stream),"onAir":\#(onAir)}"#)
    }

    /// A video station is asked for its one stream, which plays on through
    /// programs and idents: at a program's end the station is only read.
    func testAVideoStationStaysOnItsLiveStreamAndReadsWhatIsOn() async throws {
        answers = [live(Fixtures.onAir("on_air", now: Fixtures.lantern, position: 4_328_000, next: Fixtures.salt))]
        await player.tune(tuner)
        XCTAssertEqual(try XCTUnwrap(transport.json(.post, Self.ask))["live"] as? Bool, true)
        XCTAssertEqual(output.loaded.first?.0.path, "/api/v2/channels/k1/live.m3u8")
        XCTAssertEqual(output.loaded.first?.1, 0, "the player joins at the live edge")
        await until { slept.count == 2 }
        XCTAssertEqual(tuner.station.onAir.status, .betweenPrograms)
        XCTAssertEqual(slept.last, ISO8601DateFormatter().date(from: "2026-11-15T16:00:00Z"), "then at the next start")
        XCTAssertEqual(asks, 1)
        XCTAssertEqual(output.loaded.count, 1)
        XCTAssertTrue(transport.paths(.delete).isEmpty)
        XCTAssertEqual(player.stream?.sessionId, 7)
    }

    func testTuningInBetweenProgramsPlaysTheIdent() async throws {
        wakesAtOnce = false
        answers = [live(Fixtures.onAir("between_programs", next: Fixtures.salt))]
        await player.tune(tuner)
        XCTAssertFalse(tuner.offAir)
        XCTAssertEqual(output.loaded.count, 1)
        XCTAssertEqual(tuner.wakeAt, ISO8601DateFormatter().date(from: "2026-11-15T16:00:00Z"))
    }

    /// A live stream ends when nothing more airs within the hour: asked again, the station is off the air.
    func testALiveStreamEndingAsksAgain() async {
        wakesAtOnce = false
        let ends = ISO8601DateFormatter().string(from: Date().addingTimeInterval(600))
        let onAir = Fixtures.onAir("on_air", now: Fixtures.program(20, "The Lantern Keeper", ends: ends))
        answers = [live(onAir), (.conflict, Self.offAir)]
        await player.tune(tuner)
        let ended = Task { await player.programEnded(tuner) }
        await until { slept.count == 2 }
        XCTAssertEqual(asks, 1, "a player runs ahead of the schedule: the ask waits for the program's end")
        ended.cancel()
        await ended.value
        XCTAssertEqual(asks, 2)
        XCTAssertTrue(tuner.offAir)
    }

    /// Back in the foreground, or awake, the wait is armed again for the same instant.
    func testResumingArmsTheWaitAgain() async throws {
        wakesAtOnce = false
        answers = [(.conflict, Self.offAir)]
        await player.tune(tuner)
        tuner.resume()
        await until { slept.count == 2 }
        let resumes = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-15T16:00:00Z"))
        XCTAssertEqual(slept, [resumes, resumes])
        XCTAssertEqual(tuner.wakeAt, resumes)
    }

    func testOffAirDecodesWithItsResumeTime() async {
        answers = [(.conflict, Self.offAir)]
        let client = server.client(token: "t", transport: transport)
        do {
            _ = try await client.startStationPlayback(
                path: .init(stationId: 5),
                body: .json(
                    .init(
                        snapshot: CapabilitySnapshotBuilder.snapshot(
                            capabilities.facts(), server: server, maxBitrate: nil))))
            XCTFail("off air throws")
        } catch {
            let api = APIError.from(error)
            XCTAssertEqual(api?.code, .offAir)
            XCTAssertEqual(api?.resumesAt, ISO8601DateFormatter().date(from: "2026-11-15T16:00:00Z"))
        }
    }

    func testATuneInTheServerCouldNotAnswerIsAskedAgainSoon() async {
        answers = [(.badGateway, "<html>502 Bad Gateway</html>"), tuned()]
        await player.tune(tuner)
        await until { asks == 2 && !output.loaded.isEmpty }
        XCTAssertEqual(asks, 2)
        XCTAssertNil(player.error)
        XCTAssertEqual(player.stream?.sessionId, 7)
        XCTAssertEqual(slept.first?.timeIntervalSinceNow ?? 0, 5, accuracy: 1)
    }
}

@MainActor
final class MusicStationTests: XCTestCase {
    var transport: RoutingTransport!
    var output: FakeAudioOutput!
    var center: FakeNowPlaying!
    var player: MusicPlayer!
    var tuner: StationTuner!

    override func setUp() async throws {
        transport = RoutingTransport()
        transport.respond = { sent in
            switch (sent.method, sent.path) {
            case (.post, "/playback/sessions"):
                let body = (try? JSONSerialization.jsonObject(with: Data(sent.body.utf8))) as? [String: Any]
                return (.created, Fixtures.audioStream(UID(body?["itemId"] as? String ?? "") ?? 0))
            case (.post, "/stations/\(UID.n(6))/playback"):
                let stream = Fixtures.audioStream(30).replacingOccurrences(
                    of: #""positionMs":0"#, with: #""positionMs":86000"#)
                let onAir = Fixtures.onAir(
                    "on_air", now: Fixtures.program(30, "Paper Lanterns", kind: "song"), position: 86000,
                    next: Fixtures.program(31, "Slow Tide", kind: "song"))
                return (.created, #"{"stream":\#(stream),"onAir":\#(onAir)}"#)
            case (.delete, _), (.put, _): return (.noContent, "")
            default: return nil
            }
        }
        output = FakeAudioOutput()
        center = FakeNowPlaying()
        let server = ServerEndpoint(userInput: "192.168.1.9")!
        let client = server.client(token: "t", transport: transport)
        player = MusicPlayer(
            client: client, endpoint: server, profileId: 1, output: output, capabilities: FakeCapabilities(),
            activateSession: {})
        player.attach(center)
        tuner = stationTuner(
            client: client, replica: try tunerReplica(),
            station: Fixtures.decode(Fixtures.station(6, "Kitchen Radio", kind: "music")))
        await player.play(Fixtures.songs(3), source: "In Rainbows")
    }

    override func tearDown() async throws {
        tuner.cancel()
    }

    private var asks: Int { transport.paths(.post).filter { $0 == "/stations/\(UID.n(6))/playback" }.count }

    func testAStationPlaysItsSongAndLeavesTheQueueAsItWas() async {
        await player.tune(tuner)
        XCTAssertEqual(asks, 1)
        XCTAssertEqual(player.current?.id, 30)
        XCTAssertEqual(player.queue.current?.song.id, 1)
        XCTAssertEqual(output.seeks.last, 86000)
        XCTAssertTrue(player.playing)
        XCTAssertEqual(transport.paths(.delete), ["/playback/sessions/\(UID.n(1))"], "the queue's session ends")
        XCTAssertEqual(center.shown.last??.title, "Paper Lanterns")
        XCTAssertEqual(center.shown.last??.stopOnly, true)
    }

    func testOnlyStopActsOnAStation() async {
        await player.tune(tuner)
        for command in [RemoteCommand.next, .previous, .toggle, .play, .seek(ms: 0)] { await player.handle(command) }
        XCTAssertEqual(asks, 1)
        XCTAssertEqual(transport.paths(.post).count, 2, "nothing else started")
        XCTAssertTrue(player.playing)
        await player.handle(.stop)
        XCTAssertNil(player.station)
        XCTAssertFalse(player.playing)
        XCTAssertNil(player.stream)
        XCTAssertEqual(transport.paths(.delete).last, "/playback/sessions/\(UID.n(30))")
        XCTAssertEqual(player.current?.id, 1, "the viewer's own queue is back")
    }

    func testASongsEndAsksTheStationAgain() async {
        await player.tune(tuner)
        await player.songEnded()
        XCTAssertEqual(asks, 2)
        XCTAssertEqual(player.current?.id, 30)
        XCTAssertEqual(player.queue.current?.song.id, 1)
    }
}
