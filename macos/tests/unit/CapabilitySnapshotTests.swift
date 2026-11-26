import AudioToolbox
import Foundation
import RabbitEarsAPI
import XCTest

@testable import RabbitEarsKit

final class CapabilitySnapshotTests: XCTestCase {
    let facts = DeviceFacts(
        hardwareVideoCodecs: ["h264", "hevc"],
        hdrPlayback: true,
        audioDecoders: [kAudioFormatMPEG4AAC, kAudioFormatAC3, kAudioFormatEnhancedAC3, kAudioFormatFLAC, 0x7878_7878],
        playableTypes: ["public.mpeg-4", "com.apple.quicktime-movie", "public.avi"],
        screen: ScreenFacts(width: 3456, height: 2234, refreshRate: 120, edrHeadroom: 16),
        route: RouteFacts(channels: 2, physicalFormats: [kAudioFormatLinearPCM], maxSampleRate: 48000),
        path: PathFacts(expensive: false, constrained: false, vpn: false))

    func testDecoderListsHardwareCodecsWithTheirLimits() throws {
        let decoder = CapabilitySnapshotBuilder.decoder(facts)
        XCTAssertEqual(decoder.protocols, [.http, .hls])
        XCTAssertEqual(decoder.containers, ["mp4", "mov"])
        XCTAssertEqual(decoder.videoCodecs.map(\.codec), ["h264", "hevc"])
        let hevc = try XCTUnwrap(decoder.videoCodecs.last)
        XCTAssertTrue(hevc.hardware)
        XCTAssertEqual(hevc.profiles, ["Main", "Main 10"])
        XCTAssertEqual(hevc.maxBitDepth, 10)
        XCTAssertEqual(hevc.hdrFormats, [.hdr10, .hlg, .dolbyVision])
        XCTAssertEqual(decoder.videoCodecs.first?.maxLevel, 52)
        XCTAssertEqual(decoder.audioCodecs, ["aac", "ac3", "eac3", "flac"])
        XCTAssertEqual(decoder.subtitleFormats, ["webvtt", "srt"])
    }

    func testNoHDRPlaybackMeansNoDecoderHDR() {
        var sdr = facts
        sdr.hdrPlayback = false
        XCTAssertEqual(CapabilitySnapshotBuilder.decoder(sdr).videoCodecs.last?.hdrFormats, [])
    }

    func testDisplayReportsPixelsRefreshAndHDR() {
        let display = CapabilitySnapshotBuilder.display(facts.screen)
        XCTAssertEqual([display.width, display.height], [3456, 2234])
        XCTAssertEqual(display.refreshRate, 120)
        XCTAssertEqual(display.hdrFormats, [.hdr10, .hlg, .dolbyVision])
        let sdr = CapabilitySnapshotBuilder.display(
            ScreenFacts(width: 1920, height: 1080, refreshRate: 60, edrHeadroom: 1))
        XCTAssertEqual(sdr.hdrFormats, [])
    }

    func testNoScreenFallsBackToSDR1080p() {
        let display = CapabilitySnapshotBuilder.display(nil)
        XCTAssertEqual([display.width, display.height], [1920, 1080])
        XCTAssertEqual(display.hdrFormats, [])
    }

    func testAudioRoutePassesThroughOnlyWhatTheDeviceCarries() {
        XCTAssertEqual(CapabilitySnapshotBuilder.audioRoute(facts.route).passthroughCodecs, [])
        let hdmi = RouteFacts(
            channels: 8, physicalFormats: [kAudioFormatLinearPCM, kAudioFormat60958AC3, kAudioFormatEnhancedAC3],
            maxSampleRate: 192_000)
        let route = CapabilitySnapshotBuilder.audioRoute(hdmi)
        XCTAssertEqual(route.channels, 8)
        XCTAssertEqual(route.passthroughCodecs, ["ac3", "eac3"])
        XCTAssertEqual(route.maxSampleRate, 192_000)
        XCTAssertEqual(CapabilitySnapshotBuilder.audioRoute(RouteFacts(channels: 0)).channels, 2)
    }

    func testNetworkCarriesPathFactsDiscoveryAndTheCap() {
        let path = PathFacts(expensive: true, constrained: true, vpn: true)
        let local = CapabilitySnapshotBuilder.network(
            path, server: ServerEndpoint(userInput: "192.168.1.9")!, maxBitrate: nil)
        XCTAssertTrue(local.discoveredLocally)
        XCTAssertTrue(local.metered && local.lowData && local.vpn)
        XCTAssertNil(local.maxBitrate)
        let remote = CapabilitySnapshotBuilder.network(
            PathFacts(), server: ServerEndpoint(userInput: "media.example.test")!, maxBitrate: 4_000_000)
        XCTAssertFalse(remote.discoveredLocally)
        XCTAssertEqual(remote.maxBitrate, 4_000_000)
    }

    func testNetworkAsksForAutoOnlyWhenTheViewerHasNotPickedAQuality() {
        let server = ServerEndpoint(userInput: "media.example.test")!
        let auto = CapabilitySnapshotBuilder.network(PathFacts(), server: server, maxBitrate: nil, auto: true)
        XCTAssertEqual(auto.auto, true)
        XCTAssertNil(auto.maxBitrate)
        XCTAssertEqual(CapabilitySnapshotBuilder.network(PathFacts(), server: server, maxBitrate: nil).auto, false)
    }

    func testSnapshotSerializesForTheServer() throws {
        let snapshot = CapabilitySnapshotBuilder.snapshot(facts, server: .default, maxBitrate: nil)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["decoder", "display", "audioRoute", "network"])
    }

    /// The seam against real hardware: whatever Mac runs the suite decodes
    /// H.264 in hardware, AAC, and plays MP4.
    func testThisMacReportsRealFacts() async {
        let facts = await SystemCapabilities.readFacts()
        XCTAssertTrue(facts.hardwareVideoCodecs.contains("h264"))
        let decoder = CapabilitySnapshotBuilder.decoder(facts)
        XCTAssertTrue(decoder.audioCodecs.contains("aac"))
        XCTAssertTrue(decoder.containers.contains("mp4"))
        XCTAssertGreaterThanOrEqual(CapabilitySnapshotBuilder.audioRoute(facts.route).channels, 1)
    }
}
