import Foundation
import RabbitEarsAPI
import XCTest

@testable import RabbitEarsKit

@MainActor
final class FakeOutput: VideoOutput {
    var loaded: [(URL, Double)] = []
    var positionMs: Int64 = 0
    var isPaused = false
    var isBuffering = false
    var rung: (height: Int, bitrate: Int64)?
    func telemetry() async -> Components.Schemas.ThroughputTelemetry {
        .init(
            measuredBitrate: 9_000_000, bufferMs: 12_000, stallCount: 1, rungHeight: rung?.height,
            rungBitrate: rung?.bitrate)
    }
    var onFailure: ((String) -> Void)?
    var onStall: (() -> Void)?

    func load(_ url: URL, startingAt seconds: Double, bufferGoal: TimeInterval) { loaded.append((url, seconds)) }
    func play() { isPaused = false }
    func pause() { isPaused = true }
    func stop() {}
    var seeks: [Int64] = []
    func seek(toMs ms: Int64) {
        seeks.append(ms)
        positionMs = ms
    }
    var scheduled: [(ms: Int64, after: TimeInterval)] = []
    func play(atMs ms: Int64, after delay: TimeInterval) { scheduled.append((ms, delay)) }
}

@MainActor
final class FakeCapabilities: CapabilitySource {
    var onChange: ((CapabilityGroup) -> Void)?
    var current = DeviceFacts(
        hardwareVideoCodecs: ["h264", "hevc"], hdrPlayback: true, audioDecoders: [], playableTypes: ["public.mpeg-4"],
        screen: ScreenFacts(width: 3840, height: 2160, refreshRate: 60, edrHeadroom: 4),
        route: RouteFacts(channels: 2), path: PathFacts())
    /// Runs once, right after the next read: something that happens while that read's request is in flight.
    var afterNextRead: (() -> Void)?

    func facts() -> DeviceFacts {
        defer {
            let next = afterNextRead
            afterNextRead = nil
            next?()
        }
        return current
    }
}

@MainActor
final class PlayerModelTests: XCTestCase {
    var transport: RoutingTransport!
    var output: FakeOutput!
    var capabilities: FakeCapabilities!
    var model: PlayerModel!
    let server = ServerEndpoint(userInput: "192.168.1.9")!

    override func setUp() async throws {
        transport = RoutingTransport([
            "POST /playback/sessions": (.created, Fixtures.stream(position: 90_000)),
            "PUT /playback/sessions/7/position": (.noContent, ""),
            "PUT /playback/sessions/7/throughput": (.ok, Fixtures.update("continue", Fixtures.stream())),
            "DELETE /playback/sessions/7": (.noContent, ""),
        ])
        output = FakeOutput()
        capabilities = FakeCapabilities()
        let item = Fixtures.decode(Fixtures.item(20, "movie", "Dune"), as: Item.self)
        model = PlayerModel(
            client: server.client(token: "t", transport: transport), endpoint: server, profileId: 2, item: item,
            output: output, capabilities: capabilities,
            fetchText: { url in "WEBVTT\n\n00:00:01.000 --> 00:00:09.000\n\(url.lastPathComponent)\n" })
    }

    func testARowOfAPlaylistStartsWithThePlaylistId() async throws {
        let item = Fixtures.decode(Fixtures.item(21, "episode", "Hello"), as: Item.self)
        let player = PlayerModel(
            client: server.client(token: "t", transport: transport), endpoint: server, profileId: 2, item: item,
            output: output, capabilities: capabilities, playlistId: 3)
        await player.start(positionMs: 0)
        let body = try XCTUnwrap(transport.json(.post, "/playback/sessions"))
        XCTAssertEqual(body["itemId"] as? Int, 21)
        XCTAssertEqual(body["playlistId"] as? Int, 3)
        await model.start()
        XCTAssertNil(transport.json(.post, "/playback/sessions")?["playlistId"])
    }

    func testAChosenEditionStartsThatEdition() async throws {
        await model.start(editionId: 6)
        XCTAssertEqual(transport.json(.post, "/playback/sessions")?["editionId"] as? Int, 6)
    }

    func testAnEditionWithNoFileSaysItCannotPlay() async {
        transport.routes["POST /playback/sessions"] = (.conflict, Fixtures.error("conflict"))
        await model.start(editionId: 6)
        XCTAssertEqual(model.error, "This title can't play on this Mac.")
        XCTAssertTrue(output.loaded.isEmpty)
    }

    func testStartSendsTheFullSnapshotAndPlaysTheStreamAtItsPosition() async throws {
        await model.start(audioTrackId: 3)
        let body = try XCTUnwrap(transport.json(.post, "/playback/sessions"))
        XCTAssertEqual(body["profileId"] as? Int, 2)
        XCTAssertEqual(body["itemId"] as? Int, 20)
        XCTAssertEqual(body["audioTrackId"] as? Int, 3)
        XCTAssertNil(body["editionId"], "no edition plays the default")
        XCTAssertNil(body["positionMs"])
        let snapshot = try XCTUnwrap(body["snapshot"] as? [String: Any])
        XCTAssertEqual(Set(snapshot.keys), ["decoder", "display", "audioRoute", "network"])
        XCTAssertEqual((snapshot["network"] as? [String: Any])?["discoveredLocally"] as? Bool, true)
        XCTAssertEqual(output.loaded.first?.0.absoluteString, "http://192.168.1.9:8477/api/v1/streams/k1/0/file")
        XCTAssertEqual(output.loaded.first?.1, 90)
        XCTAssertEqual(model.pill, "4K HDR · Direct play · 38 Mb/s")
        XCTAssertNil(model.error)
    }

    func testARouteChangeReportsPositionThenResumesTheNewStreamThere() async {
        transport.routes["PUT /playback/sessions/7/audio-route"] =
            (
                .ok,
                Fixtures.update(
                    "restart",
                    Fixtures.stream(
                        url: "/api/v1/streams/k2/1/master.m3u8", position: 125_000,
                        verdict: "audio_transcode"))
            )
        await model.start()
        output.positionMs = 125_000
        capabilities.current.route = RouteFacts(channels: 2)
        await model.capabilitiesChanged(.audioRoute)
        let puts = transport.paths(.put)
        XCTAssertEqual(puts, ["/playback/sessions/7/position", "/playback/sessions/7/audio-route"])
        XCTAssertEqual(transport.json(.put, "/playback/sessions/7/position")?["positionMs"] as? Int, 125_000)
        XCTAssertEqual(output.loaded.last?.0.lastPathComponent, "master.m3u8")
        XCTAssertEqual(output.loaded.last?.1, 125)
        XCTAssertEqual(model.stream?.entry.verdict, .audioTranscode)
        XCTAssertFalse(model.adjusting)
    }

    func testARestartWhilePausedStaysPaused() async {
        transport.routes["PUT /playback/sessions/7/display"] =
            (.ok, Fixtures.update("restart", Fixtures.stream(url: "/api/v1/streams/k2/1/master.m3u8")))
        output.isPaused = true
        await model.start()
        XCTAssertFalse(output.isPaused, "the first load plays")
        output.pause()
        await model.capabilitiesChanged(.display)
        XCTAssertEqual(output.loaded.count, 2)
        XCTAssertTrue(output.isPaused)
    }

    func testAContinueKeepsTheCurrentStream() async {
        transport.routes["PUT /playback/sessions/7/display"] = (.ok, Fixtures.update("continue", Fixtures.stream()))
        await model.start()
        await model.capabilitiesChanged(.display)
        XCTAssertEqual(output.loaded.count, 1)
    }

    func testQualityMenuListsOriginalFirstAndCapsTheNetworkGroup() async throws {
        transport.routes["PUT /playback/sessions/7/network"] =
            (
                .ok,
                Fixtures.update(
                    "restart",
                    Fixtures.stream(
                        url: "/api/v1/streams/k3/2/master.m3u8",
                        verdict: "video_transcode"))
            )
        await model.start()
        let options = model.qualityOptions
        XCTAssertEqual(options.map(\.name), ["Original", "1080p"])
        XCTAssertEqual(options.map(\.verdictLabel), ["Direct play", "Transcode"])
        XCTAssertEqual(options.first?.detail, "4K HDR · 38 Mb/s")
        XCTAssertEqual(options.map(\.selected), [true, false])
        await model.selectQuality(options[1])
        XCTAssertEqual(transport.json(.put, "/playback/sessions/7/network")?["maxBitrate"] as? Int, 8_000_000)
        XCTAssertEqual(model.qualityOptions.map(\.selected), [false, true])
        XCTAssertEqual(output.loaded.count, 2)
    }

    func testAClientFailureMovesDownThePlan() async {
        transport.routes["POST /playback/sessions/7/events"] =
            (
                .ok,
                Fixtures.update("restart", Fixtures.stream(url: "/api/v1/streams/k4/1/master.m3u8", verdict: "remux"))
            )
        await model.start()
        await model.playerFailed("Cannot decode")
        let event = transport.json(.post, "/playback/sessions/7/events")
        XCTAssertEqual(event?["kind"] as? String, "client_failure")
        XCTAssertEqual(event?["reason"] as? String, "Cannot decode")
        XCTAssertEqual(model.stream?.entry.verdict, .remux)
    }

    func testRunningOutOfPlanSaysSo() async {
        transport.routes["POST /playback/sessions/7/events"] = (.conflict, Fixtures.error("conflict", "no entry left"))
        await model.start()
        await model.playerFailed("Cannot decode")
        XCTAssertEqual(model.error, "This title can't play on this Mac.")
    }

    func testTicksReportPositionAndThroughput() async {
        await model.start()
        output.positionMs = 30_000
        await model.tick()
        let sent = transport.json(.put, "/playback/sessions/7/throughput")
        XCTAssertEqual(sent?["positionMs"] as? Int, 30_000)
        XCTAssertEqual(sent?["stallCount"] as? Int, 1)
        XCTAssertFalse(transport.paths(.put).contains("/playback/sessions/7/position"))
    }

    /// A file with a forced, a full and a bitmap English track. As the server
    /// does, every stream carries one sidecar at most: the track chosen when
    /// it is text, none when it is burned in, else the forced track.
    func serveSubtitles() {
        func sidecar(_ id: Int64) -> String {
            #"{"trackId":\#(id),"language":"eng","format":"webvtt","forced":\#(id == 4),"#
                + #""url":"/api/v1/streams/k1/0/subtitles/\#(id).vtt"}"#
        }
        func track(_ id: Int64, _ kind: String, _ codec: String, text: Bool? = nil) -> String {
            #"{"id":\#(id),"streamIndex":\#(id),"kind":"\#(kind)","codec":"\#(codec)","language":"eng","#
                + #""isDefault":false,"isForced":\#(id == 4)\#(text.map { #","subtitleIsText":\#($0)"# } ?? "")}"#
        }
        let tracks = [
            track(3, "audio", "aac"), track(4, "subtitle", "subrip", text: true),
            track(5, "subtitle", "subrip", text: true), track(6, "subtitle", "hdmv_pgs_subtitle", text: false),
        ]
        transport.routes["GET /media-files/1"] = (
            .ok,
            #"{"id":1,"itemId":20,"path":"/m/Dune.mkv","sizeBytes":1,"modifiedAt":"2026-01-01T00:00:00Z","#
                + #""chapters":[],"tracks":[\#(tracks.joined(separator: ","))]}"#
        )
        transport.routes["POST /playback/sessions"] = (.created, Fixtures.stream(sidecars: sidecar(4)))
        transport.respond = { sent in
            guard sent.method == .put, sent.path == "/playback/sessions/7/tracks" else { return nil }
            let body = (try? JSONSerialization.jsonObject(with: Data(sent.body.utf8))) as? [String: Any]
            switch body?["subtitleTrackId"] as? Int {
            case 5: return (.ok, Fixtures.update("restart", Fixtures.stream(sidecars: sidecar(5))))
            case 6: return (.ok, Fixtures.update("restart", Fixtures.stream(verdict: "video_transcode")))
            default: return (.ok, Fixtures.update("continue", Fixtures.stream(sidecars: sidecar(4))))
            }
        }
    }

    func testSubtitlesComeFromTheSidecarAndCanBeTurnedOff() async {
        serveSubtitles()
        await model.start()
        XCTAssertEqual(model.cue(at: 2), "4.vtt")
        await model.selectSubtitles(.off)
        XCTAssertNil(model.cue(at: 2))
        XCTAssertEqual(transport.json(.put, "/playback/sessions/7/tracks")?.keys.contains("subtitleTrackId"), false)
        await model.selectSubtitles(.forcedOnly)
        XCTAssertEqual(model.cue(at: 2), "4.vtt")
    }

    func testTheSubtitleMenuListsTheFilesTracksAndAPickKeepsTheAudioTrack() async throws {
        serveSubtitles()
        await model.start(audioTrackId: 3)
        XCTAssertEqual(model.stream?.sidecars.map(\.trackId), [4], "the stream names only the track drawn")
        XCTAssertEqual(model.subtitleTracks.map(\.id), [4, 5, 6])

        await model.selectSubtitles(.track(5))
        let picked = try XCTUnwrap(transport.json(.put, "/playback/sessions/7/tracks"))
        XCTAssertEqual(picked["subtitleTrackId"] as? Int, 5)
        XCTAssertEqual(picked["audioTrackId"] as? Int, 3, "the server replaces the whole selection")
        XCTAssertEqual(model.cue(at: 2), "5.vtt")

        await model.selectSubtitles(.track(6))
        XCTAssertEqual(transport.json(.put, "/playback/sessions/7/tracks")?["subtitleTrackId"] as? Int, 6)
        XCTAssertNil(model.cue(at: 2), "a bitmap track is burned in, not drawn")
        XCTAssertEqual(model.subtitleTracks.map(\.id), [4, 5, 6])
        XCTAssertEqual(transport.paths(.get), ["/media-files/1"], "one read serves every stream of the file")
    }

    func testAThroughputAnswerOfRestartSwitchesStreamsAtTheSamePosition() async {
        transport.routes["PUT /playback/sessions/7/throughput"] =
            (
                .ok,
                Fixtures.update(
                    "restart",
                    Fixtures.stream(
                        url: "/api/v1/streams/k6/0/master.m3u8", position: 300_000, verdict: "video_transcode"))
            )
        await model.start()
        output.positionMs = 300_000
        await model.tick()
        XCTAssertEqual(transport.json(.put, "/playback/sessions/7/throughput")?["positionMs"] as? Int, 300_000)
        XCTAssertEqual(output.loaded.last?.0.lastPathComponent, "master.m3u8")
        XCTAssertEqual(output.loaded.last?.1, 300)
    }

    func testAFailedTelemetryReportLeavesPlaybackAlone() async {
        await model.start()
        transport.routes["PUT /playback/sessions/7/throughput"] = (.internalServerError, Fixtures.error("internal"))
        transport.routes["POST /playback/sessions/7/events"] = (.internalServerError, Fixtures.error("internal"))
        await model.tick()
        await model.stalled()
        XCTAssertNil(model.error)
        XCTAssertEqual(output.loaded.count, 1)
    }

    func testAFailedCapabilityUpdateLeavesPlaybackAloneAndIsResentOnTheNextTick() async {
        await model.start()
        transport.routes["PUT /playback/sessions/7/network"] = (.internalServerError, Fixtures.error("internal"))
        capabilities.current.path = PathFacts(expensive: true)
        await model.capabilitiesChanged(.network)
        await model.selectQuality(model.qualityOptions[1])
        XCTAssertNil(model.error)
        transport.routes["PUT /playback/sessions/7/network"] = (.ok, Fixtures.update("continue", Fixtures.stream()))
        await model.tick()
        await model.tick()
        XCTAssertEqual(transport.paths(.put).filter { $0.hasSuffix("/network") }.count, 3, "resent once, then heard")
        XCTAssertEqual(transport.json(.put, "/playback/sessions/7/network")?["maxBitrate"] as? Int, 8_000_000)
    }

    func testAPathChangeWhileTheSessionStartsIsSentOnceItExists() async throws {
        transport.routes["PUT /playback/sessions/7/network"] =
            (
                .ok,
                Fixtures.update(
                    "restart",
                    Fixtures.stream(url: "/api/v1/streams/k5/0/master.m3u8", position: 90_000, verdict: "remux"))
            )
        capabilities.afterNextRead = { self.capabilities.current.path = PathFacts(expensive: true) }
        await model.start()
        let network = try XCTUnwrap(transport.json(.put, "/playback/sessions/7/network"))
        XCTAssertEqual(network["metered"] as? Bool, true)
        XCTAssertEqual(network["auto"] as? Bool, true)
        XCTAssertNil(network["maxBitrate"])
        XCTAssertEqual(output.loaded.last?.0.lastPathComponent, "master.m3u8")
    }

    func testStoppingWhileTheSessionStartsEndsItUnplayed() async {
        capabilities.afterNextRead = { Task { await self.model.stop() } }
        await model.start()
        XCTAssertTrue(output.loaded.isEmpty)
        XCTAssertEqual(transport.paths(.delete), ["/playback/sessions/7"])
        XCTAssertNil(model.stream)
    }

    func testAViewClosingWhileTheSessionStartsStillEndsIt() async {
        let arrived = expectation(description: "the start is in flight")
        let release = DispatchSemaphore(value: 0)
        transport.respond = { sent in
            if sent.method == .post {
                arrived.fulfill()
                release.wait()
            }
            return nil
        }
        let model = model!
        let view = Task { await model.start() }
        await fulfillment(of: [arrived], timeout: 5)
        view.cancel()
        await model.stop()
        release.signal()
        await view.value
        XCTAssertTrue(output.loaded.isEmpty)
        XCTAssertEqual(transport.paths(.delete), ["/playback/sessions/7"])
        XCTAssertNil(model.error)
    }

    func testARestartAnsweredAfterStopIsNotPlayed() async {
        transport.routes["PUT /playback/sessions/7/audio-route"] =
            (.ok, Fixtures.update("restart", Fixtures.stream(url: "/api/v1/streams/k2/1/master.m3u8")))
        await model.start()
        capabilities.afterNextRead = { Task { await self.model.stop() } }
        await model.capabilitiesChanged(.audioRoute)
        XCTAssertEqual(output.loaded.count, 1)
    }

    func testStopEndsAtThePosition() async {
        await model.start()
        output.positionMs = 42_000
        await model.stop()
        XCTAssertEqual(transport.paths(.delete), ["/playback/sessions/7"])
        XCTAssertEqual(transport.queries(.delete, "/playback/sessions/7"), ["positionMs=42000"])
        XCTAssertFalse(transport.paths(.put).contains("/playback/sessions/7/position"))
        XCTAssertNil(model.stream)
    }
}

extension PlayerModelTests {
    func testNextSubtitlesStepsThroughTheMenuInOrder() async {
        serveSubtitles()
        await model.start()
        var seen: [PlayerModel.SubtitleChoice] = []
        for _ in 0..<5 {
            await model.nextSubtitles()
            seen.append(model.subtitleChoice)
        }
        XCTAssertEqual(seen, [.track(4), .track(5), .track(6), .off, .forcedOnly])
        await model.nextSubtitles(offeringTracks: false)
        XCTAssertEqual(model.subtitleChoice, .off, "without tracks it is Off and Forced only")
    }
}
