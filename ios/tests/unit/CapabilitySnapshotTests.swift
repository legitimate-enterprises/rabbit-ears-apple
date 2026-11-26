import Foundation
import RabbitEarsAPI
import XCTest

@testable import RabbitEarsKit

@MainActor
final class CapabilitySnapshotTests: XCTestCase {
    let server = ServerEndpoint(userInput: "media.example.test")!

    func testScreenIsReportedInLandscapePixels() {
        let screen = SystemCapabilities.screenFacts(
            nativeSize: CGSize(width: 1179, height: 2556), refreshRate: 120, edrHeadroom: 8)
        let display = CapabilitySnapshotBuilder.display(screen)
        XCTAssertEqual([display.width, display.height], [2556, 1179])
        XCTAssertEqual(display.refreshRate, 120)
        XCTAssertEqual(display.hdrFormats, [.hdr10, .hlg, .dolbyVision])
        let sdr = SystemCapabilities.screenFacts(
            nativeSize: CGSize(width: 750, height: 1334), refreshRate: 60, edrHeadroom: 1)
        XCTAssertEqual(CapabilitySnapshotBuilder.display(sdr).hdrFormats, [])
    }

    func testAudioRouteCarriesChannelsAndRateButNoPassthrough() {
        let phone = CapabilitySnapshotBuilder.audioRoute(SystemCapabilities.routeFacts(channels: 2, sampleRate: 48000))
        XCTAssertEqual(phone.channels, 2)
        XCTAssertEqual(phone.passthroughCodecs, [])
        XCTAssertEqual(phone.maxSampleRate, 48000)
        let airPlay = CapabilitySnapshotBuilder.audioRoute(SystemCapabilities.routeFacts(channels: 6, sampleRate: 0))
        XCTAssertEqual(airPlay.channels, 6)
        XCTAssertNil(airPlay.maxSampleRate)
    }

    func testCellularIsMeteredAndLowDataModeIsLowData() {
        let route = SystemCapabilities.routeFacts(channels: 2, sampleRate: 48000)
        let cellular = SystemCapabilities.readFacts(
            screen: nil, route: route, path: PathFacts(expensive: true, constrained: false))
        let network = CapabilitySnapshotBuilder.snapshot(cellular, server: server, maxBitrate: nil, auto: true).network
        XCTAssertTrue(network.metered)
        XCTAssertFalse(network.lowData)
        XCTAssertEqual(network.auto, true)
        XCTAssertFalse(network.discoveredLocally)
        let lowData = SystemCapabilities.readFacts(
            screen: nil, route: route, path: PathFacts(expensive: false, constrained: true))
        XCTAssertTrue(CapabilitySnapshotBuilder.snapshot(lowData, server: server, maxBitrate: nil).network.lowData)
    }

    func testDecoderFactsAreProbedFromAVFoundation() {
        let facts = SystemCapabilities.readFacts(screen: nil, route: RouteFacts(channels: 2), path: PathFacts())
        let decoder = CapabilitySnapshotBuilder.decoder(facts)
        XCTAssertEqual(decoder.protocols, [.http, .hls])
        XCTAssertTrue(decoder.containers.contains("mp4"))
        XCTAssertTrue(decoder.audioCodecs.contains("aac"))
        XCTAssertNil(decoder.segmentFormats)
    }

    func testQualityHeadingNamesTheLimitAwayAndTheRouteAtHome() {
        XCTAssertEqual(QualityHeading.text(away: false, path: PathFacts(), airPlay: nil), "Playing on this iPhone")
        XCTAssertEqual(
            QualityHeading.text(away: false, path: PathFacts(), airPlay: "Living room"), "Playing on Living room")
        XCTAssertEqual(QualityHeading.text(away: true, path: PathFacts(), airPlay: nil), "Away from home")
        XCTAssertEqual(
            QualityHeading.text(away: true, path: PathFacts(expensive: true), airPlay: nil),
            "On cellular, up to 4 Mb/s")
        XCTAssertEqual(
            QualityHeading.text(away: true, path: PathFacts(expensive: true, constrained: true), airPlay: nil),
            "Low Data Mode, up to 1.5 Mb/s")
    }
}
