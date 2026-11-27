import Foundation
import HTTPTypes
import RabbitEarsAPI
import XCTest

@testable import RabbitEarsKit

/// The places a playback starts or hears of a new path, on an endpoint signed in to at a public address.
@MainActor
final class HomePlaybackTests: XCTestCase {
    let server = ServerEndpoint(userInput: "https://media.example.test")!
    var transport: RoutingTransport!
    var client: Client!

    override func setUp() async throws {
        transport = RoutingTransport([
            "POST /playback/sessions": (
                .created,
                Fixtures.stream(
                    sidecars: #"{"trackId":4,"language":"eng","format":"webvtt","forced":true,"#
                        + #""url":"/api/v1/streams/k1/0/subtitles/4.vtt"}"#, extra: Fixtures.autoExtra)
            ),
            "PUT /playback/sessions/7/position": (.noContent, ""),
            "PUT /playback/sessions/7/network": (
                .ok, Fixtures.update("restart", Fixtures.stream(url: "/api/v1/streams/k2/0/master.m3u8"))
            ),
            "DELETE /playback/sessions/7": (.noContent, ""),
        ])
        client = server.client(token: "t", transport: transport)
    }

    /// Confirms through the faked server, which then answers no further check.
    private func arriveHome() async {
        transport.serveLocalChecks()
        await server.confirmHome(using: client, on: PathFacts(), force: true, transport: transport)
        transport.respond = nil
        XCTAssertTrue(server.atHome)
    }

    /// What the last such request said of discovery, wherever its network group sits.
    private func discoveredLocally(_ method: HTTPRequest.Method, _ path: String) -> Bool? {
        let body = transport.json(method, path)
        let snapshot = body?["snapshot"] as? [String: Any] ?? body
        return (snapshot?["network"] as? [String: Any] ?? body)?["discoveredLocally"] as? Bool
    }

    private func index(_ path: String) -> Int? { transport.sent.lastIndex { $0.path == path } }
    private var checks: Int { transport.paths(.post).filter { $0 == "/local-checks" }.count }

    private func movie(_ output: FakeOutput, _ capabilities: FakeCapabilities = FakeCapabilities()) -> PlayerModel {
        PlayerModel(
            client: client, endpoint: server, profileId: 2,
            item: Fixtures.decode(Fixtures.item(20, "movie", "Dune"), as: Item.self), output: output,
            capabilities: capabilities)
    }

    func testAStreamTheServerKeepsIsLoadedAgainOnceItsAddressIsGone() async throws {
        await arriveHome()
        let kept = (HTTPResponse.Status.ok, Fixtures.update("continue", Fixtures.stream(position: 61_000)))
        transport.routes["PUT /playback/sessions/7/network"] = kept
        transport.routes["PUT /playback/sessions/7/throughput"] = kept
        let output = FakeOutput()
        let capabilities = FakeCapabilities()
        let model = movie(output, capabilities)
        await model.start()
        capabilities.current.path = PathFacts(expensive: true)
        await model.capabilitiesChanged(.network)
        XCTAssertEqual(output.loaded.count, 2)
        XCTAssertEqual(output.loaded.last?.0.absoluteString, "https://media.example.test/api/v1/streams/k1/0/file")
        XCTAssertEqual(output.loaded.last?.1, 61)
        await model.tick()
        XCTAssertEqual(transport.paths(.put).last, "/playback/sessions/7/throughput")
        XCTAssertEqual(output.loaded.count, 2, "loaded once")
        await model.stop()
    }

    func testAPlayerThatFailsAtHomeChecksBeforeTheNextEntryLoads() async throws {
        await arriveHome()
        transport.routes["POST /playback/sessions/7/events"] = (
            .ok, Fixtures.update("restart", Fixtures.stream(url: "/api/v1/streams/k1/1/master.m3u8"))
        )
        let output = FakeOutput()
        let model = movie(output)
        await model.start()
        await model.playerFailed("The network connection was lost.")
        XCTAssertEqual(checks, 2)
        XCTAssertLessThan(try XCTUnwrap(index("/local-checks")), try XCTUnwrap(index("/playback/sessions/7/events")))
        XCTAssertEqual(
            output.loaded.last?.0.absoluteString, "https://media.example.test/api/v1/streams/k1/1/master.m3u8")
        await model.playerFailed("Cannot decode")
        XCTAssertEqual(checks, 2, "away, a failure waits on no check")
        await model.stop()
    }

    func testASongThatFailsAtHomeChecksBeforeTheNextEntryLoads() async throws {
        transport.routes["POST /playback/sessions"] = (.created, Fixtures.audioStream(1))
        transport.routes["PUT /playback/sessions/1/position"] = (.noContent, "")
        transport.routes["DELETE /playback/sessions/1"] = (.noContent, "")
        transport.routes["POST /playback/sessions/1/events"] = (
            .ok, Fixtures.update("restart", Fixtures.audioStream(1, verdict: "audio_transcode", position: 9000))
        )
        await arriveHome()
        let output = FakeAudioOutput()
        let player = MusicPlayer(
            client: client, endpoint: server, profileId: 1, output: output, capabilities: FakeCapabilities(),
            activateSession: {})
        await player.play(Fixtures.songs(1), source: "In Rainbows")
        XCTAssertEqual(output.loaded.last?.host(), "10.0.0.2")
        await player.outputFailed("The network connection was lost.")
        XCTAssertEqual(checks, 2)
        XCTAssertLessThan(try XCTUnwrap(index("/local-checks")), try XCTUnwrap(index("/playback/sessions/1/events")))
        XCTAssertEqual(output.loaded.last?.host(), "media.example.test")
        await player.stop()
    }

    func testAtHomeAMoviePlaysFromTheLocalAddressUntilAPathChangeLeavesIt() async throws {
        await arriveHome()
        let output = FakeOutput()
        let capabilities = FakeCapabilities()
        let model = PlayerModel(
            client: client, endpoint: server, profileId: 2,
            item: Fixtures.decode(Fixtures.item(20, "movie", "Dune"), as: Item.self), output: output,
            capabilities: capabilities,
            fetchText: { url in "WEBVTT\n\n00:00:01.000 --> 00:00:09.000\n\(url.host() ?? "")\n" })
        await model.start()
        XCTAssertEqual(discoveredLocally(.post, "/playback/sessions"), true)
        XCTAssertEqual(output.loaded.last?.0.absoluteString, "\(Fixtures.lan)/api/v1/streams/k1/0/file")
        XCTAssertEqual(model.cue(at: 2), "media.example.test", "subtitles stay on the address signed in at")
        XCTAssertEqual(model.previewURL(at: 0)?.host(), "media.example.test")
        XCTAssertEqual(checks, 1, "a fresh check stands")
        await model.capabilitiesChanged(.network)
        XCTAssertEqual(checks, 1, "a quality pick is no new path")
        XCTAssertEqual(output.loaded.last?.0.host(), "10.0.0.2")

        capabilities.current.path = PathFacts(expensive: true)
        await model.capabilitiesChanged(.network)
        XCTAssertFalse(server.atHome)
        XCTAssertEqual(discoveredLocally(.put, "/playback/sessions/7/network"), false)
        XCTAssertLessThan(
            try XCTUnwrap(index("/local-checks")), try XCTUnwrap(index("/playback/sessions/7/network")))
        XCTAssertEqual(
            output.loaded.last?.0.absoluteString, "https://media.example.test/api/v1/streams/k2/0/master.m3u8")
        await model.stop()
    }

    func testAMovieStartChecksFirst() async throws {
        let model = PlayerModel(
            client: client, endpoint: server, profileId: 2,
            item: Fixtures.decode(Fixtures.item(20, "movie", "Dune"), as: Item.self), output: FakeOutput(),
            capabilities: FakeCapabilities())
        await model.start()
        XCTAssertEqual(transport.paths(.post), ["/local-checks", "/playback/sessions"])
        XCTAssertEqual(discoveredLocally(.post, "/playback/sessions"), false)
        await model.stop()
    }

    func testASongAndAStationCheckFirstAndPlayFromTheLocalAddressAtHome() async throws {
        transport.routes["POST /playback/sessions"] = (.created, Fixtures.audioStream(1))
        transport.routes["PUT /playback/sessions/1/position"] = (.noContent, "")
        transport.routes["DELETE /playback/sessions/1"] = (.noContent, "")
        transport.routes["DELETE /playback/sessions/30"] = (.noContent, "")
        let onAir = Fixtures.onAir("on_air", now: Fixtures.program(30, "Paper Lanterns", kind: "song"), position: 0)
        transport.routes["POST /stations/6/playback"] = (
            .created, #"{"stream":\#(Fixtures.audioStream(30)),"onAir":\#(onAir)}"#
        )
        let output = FakeAudioOutput()
        let player = MusicPlayer(
            client: client, endpoint: server, profileId: 1, output: output, capabilities: FakeCapabilities(),
            activateSession: {})
        let tuner = stationTuner(
            client: client, replica: try tunerReplica(),
            station: Fixtures.decode(Fixtures.station(6, "Kitchen Radio", kind: "music")))

        await player.play(Fixtures.songs(1), source: "In Rainbows")
        await player.tune(tuner)
        XCTAssertEqual(
            transport.paths(.post), ["/local-checks", "/playback/sessions", "/stations/6/playback"],
            "the first check stands for the station")
        XCTAssertEqual(discoveredLocally(.post, "/stations/6/playback"), false)
        XCTAssertEqual(output.loaded.map { $0.host() }, ["media.example.test", "media.example.test"])

        await arriveHome()
        await player.leaveStation()
        await player.play(Fixtures.songs(1), source: "In Rainbows")
        XCTAssertEqual(discoveredLocally(.post, "/playback/sessions"), true)
        await player.tune(tuner)
        XCTAssertEqual(discoveredLocally(.post, "/stations/6/playback"), true)
        XCTAssertEqual(
            output.loaded.suffix(2).map(\.absoluteString),
            ["\(Fixtures.lan)/api/v1/streams/s1/0/file", "\(Fixtures.lan)/api/v1/streams/s30/0/file"])
        await player.stop()
        tuner.cancel()
    }

    func testPlayabilityChecksFirst() async throws {
        transport.routes["POST /items/20/playability"] = (
            .ok,
            #"{"verdict":"direct_play","negotiated":{"verdict":"direct_play","width":1920,"height":1080,"#
                + #""bitrate":8000000}}"#
        )
        let model = CatalogModel(client: client, profileId: 2)
        let facts = FakeCapabilities().current
        let away = await model.playability(20, facts: facts, server: server)
        XCTAssertEqual(away?.verdict, .directPlay)
        XCTAssertEqual(transport.paths(.post), ["/local-checks", "/items/20/playability"])
        XCTAssertEqual(discoveredLocally(.post, "/items/20/playability"), false)
        await arriveHome()
        _ = await model.playability(20, facts: facts, server: server)
        XCTAssertEqual(discoveredLocally(.post, "/items/20/playability"), true)
    }
}
