import Foundation
import RabbitEarsAPI
import XCTest

@testable import RabbitEarsKit

/// Away from home: Auto first and chosen, then Original and the rungs.
@MainActor
final class QualityTests: XCTestCase {
    static let awayLadder =
        #"[{"width":3840,"height":2160,"bitrate":38000000,"verdict":"remux"},"#
        + #"{"width":1920,"height":1080,"bitrate":8000000,"verdict":"video_transcode"},"#
        + #"{"width":1280,"height":720,"bitrate":4000000,"verdict":"video_transcode"},"#
        + #"{"width":854,"height":480,"bitrate":1500000,"verdict":"video_transcode","blocked":false}]"#
    static let meteredLadder =
        #"[{"width":3840,"height":2160,"bitrate":38000000,"verdict":"remux","blocked":true},"#
        + #"{"width":1920,"height":1080,"bitrate":8000000,"verdict":"video_transcode","blocked":true},"#
        + #"{"width":1280,"height":720,"bitrate":4000000,"verdict":"video_transcode"},"#
        + #"{"width":854,"height":480,"bitrate":1500000,"verdict":"video_transcode"}]"#

    var transport: RoutingTransport!
    var output: FakeOutput!
    var model: PlayerModel!
    let server = ServerEndpoint(userInput: "media.example.test")!

    func makeModel(ladder: String = awayLadder, extra: String = Fixtures.autoExtra) {
        let stream = Fixtures.stream(verdict: "video_transcode", rungs: ladder, extra: extra)
        transport = RoutingTransport([
            "POST /playback/sessions": (.created, stream),
            "PUT /playback/sessions/7/position": (.noContent, ""),
            "PUT /playback/sessions/7/throughput": (.ok, Fixtures.update("continue", stream)),
            "PUT /playback/sessions/7/network": (.ok, Fixtures.update("continue", stream)),
        ])
        output = FakeOutput()
        model = PlayerModel(
            client: server.client(token: "t", transport: transport), endpoint: server, profileId: 2,
            item: Fixtures.decode(Fixtures.item(20, "movie", "Dune"), as: Item.self), output: output,
            capabilities: FakeCapabilities())
    }

    func testAwayMenuLeadsWithAutoThenOriginalLabeledByItsVerdictThenTheRungs() async {
        makeModel()
        await model.start()
        let options = model.qualityOptions
        XCTAssertEqual(options.map(\.name), ["Auto", "Original", "1080p", "720p", "480p"])
        XCTAssertEqual(options.map(\.selected), [true, false, false, false, false])
        XCTAssertEqual(options.map(\.trailingLabel), ["Transcode", "Remux", "Transcode", "Transcode", "Transcode"])
        XCTAssertEqual(options.first?.detail, "Now 4K · adjusts to your connection")
        XCTAssertEqual(options[1].detail, "4K HDR · 38 Mb/s")
    }

    func testAtHomeTheMenuHasNoAutoAndOriginalIsSelected() async {
        makeModel(ladder: Fixtures.ladder, extra: "")
        await model.start()
        XCTAssertEqual(model.qualityOptions.map(\.name), ["Original", "1080p"])
        XCTAssertEqual(model.qualityOptions.map(\.selected), [true, false])
    }

    func testMeteredPathDisablesWhatIsAboveItAsWiFiOnly() async {
        makeModel(ladder: Self.meteredLadder)
        await model.start()
        let options = model.qualityOptions
        XCTAssertEqual(options.map(\.blocked), [false, true, true, false, false])
        XCTAssertEqual(
            options.map(\.trailingLabel), ["Transcode", "Wi-Fi only", "Wi-Fi only", "Transcode", "Transcode"])
    }

    func testABlockedPickIsIgnored() async {
        makeModel(ladder: Self.meteredLadder)
        await model.start()
        await model.selectQuality(model.qualityOptions[2])
        XCTAssertEqual(model.quality, .auto)
        XCTAssertTrue(transport.paths(.put).filter { $0.hasSuffix("/network") }.isEmpty)
    }

    func testPillReadsTheRungInUseThenAutoThenItsBitrate() async {
        makeModel(extra: Fixtures.autoExtra)
        await model.start()
        XCTAssertEqual(model.pill, "4K · Auto · 38 Mb/s")
        output.rung = (height: 1080, bitrate: 8_000_000)
        await model.tick()
        XCTAssertEqual(model.pill, "1080p · Auto · 8 Mb/s")
        XCTAssertEqual(model.qualityOptions.first?.detail, "Now 1080p · adjusts to your connection")
    }

    func testTelemetryCarriesTheRungInUse() async {
        makeModel()
        await model.start()
        output.rung = (height: 720, bitrate: 4_000_000)
        await model.tick()
        let sent = transport.json(.put, "/playback/sessions/7/throughput")
        XCTAssertEqual(sent?["rungHeight"] as? Int, 720)
        XCTAssertEqual(sent?["rungBitrate"] as? Int, 4_000_000)
    }

    func testStartAsksForAutoAndEachPickSendsItsNetworkGroup() async throws {
        makeModel()
        await model.start()
        let snapshot = try XCTUnwrap(transport.json(.post, "/playback/sessions")?["snapshot"] as? [String: Any])
        let first = try XCTUnwrap(snapshot["network"] as? [String: Any])
        XCTAssertEqual(first["auto"] as? Bool, true)
        XCTAssertNil(first["maxBitrate"])

        await model.selectQuality(model.qualityOptions[2])
        var group = try XCTUnwrap(transport.json(.put, "/playback/sessions/7/network"))
        XCTAssertEqual(group["auto"] as? Bool, false)
        XCTAssertEqual(group["maxBitrate"] as? Int, 8_000_000)
        XCTAssertEqual(model.qualityOptions.map(\.selected), [false, false, true, false, false])

        await model.selectQuality(model.qualityOptions[1])
        group = try XCTUnwrap(transport.json(.put, "/playback/sessions/7/network"))
        XCTAssertEqual(group["auto"] as? Bool, false)
        XCTAssertNil(group["maxBitrate"])

        await model.selectQuality(model.qualityOptions[0])
        group = try XCTUnwrap(transport.json(.put, "/playback/sessions/7/network"))
        XCTAssertEqual(group["auto"] as? Bool, true)
        XCTAssertNil(group["maxBitrate"])
    }

    func testPickingWhatIsAlreadyInEffectSendsNothing() async {
        makeModel()
        await model.start()
        await model.selectQuality(model.qualityOptions[0])
        XCTAssertTrue(transport.paths(.put).filter { $0.hasSuffix("/network") }.isEmpty)
    }

    func testTheStreamCarriesPreviewsAndTheModelBuildsFrameURLs() async {
        makeModel()
        await model.start()
        XCTAssertEqual(
            model.previewURL(at: 604.0)?.absoluteString,
            "http://media.example.test:8477/api/v1/streams/k1/0/previews/60.jpg")
    }

    func testNoPreviewsMeansNoPreviewURL() async {
        makeModel(extra: "")
        await model.start()
        XCTAssertNil(model.previewURL(at: 30))
    }
}

final class QualityFormatTests: XCTestCase {
    func testAutoPillNamesTheRungAndAutoWithoutHDR() {
        let negotiated = Components.Schemas.Negotiated(
            verdict: .videoTranscode, width: 3840, height: 2160, hdrFormat: .hdr10, bitrate: 38_000_000)
        XCTAssertEqual(
            Format.pill(negotiated, auto: .init(height: 1080, bitrate: 8_000_000)), "1080p · Auto · 8 Mb/s")
        XCTAssertEqual(Format.pill(negotiated, auto: .init(height: 480, bitrate: 1_500_000)), "480p · Auto · 1.5 Mb/s")
        XCTAssertEqual(Format.pill(negotiated, auto: nil), "4K HDR · Transcode · 38 Mb/s")
    }

    func testTelemetryNamesTheRungOnlyWhenThePlayerKnowsIt() {
        let hls = Telemetry.sample(
            observedBitrate: 9e6, bufferSeconds: 12.5, stalls: 2, height: 1080, indicatedBitrate: 8e6)
        XCTAssertEqual([hls.measuredBitrate, hls.bufferMs], [9_000_000, 12_500])
        XCTAssertEqual(hls.stallCount, 2)
        XCTAssertEqual(hls.rungHeight, 1080)
        XCTAssertEqual(hls.rungBitrate, 8_000_000)
        let file = Telemetry.sample(
            observedBitrate: .nan, bufferSeconds: .infinity, stalls: 0, height: 0, indicatedBitrate: -1)
        XCTAssertEqual([file.measuredBitrate, file.bufferMs], [0, 0])
        XCTAssertNil(file.rungHeight)
        XCTAssertNil(file.rungBitrate)
        let half = Telemetry.sample(
            observedBitrate: 1, bufferSeconds: 1, stalls: 0, height: 720, indicatedBitrate: -1)
        XCTAssertNil(half.rungHeight)
        XCTAssertNil(half.rungBitrate)
    }
}
