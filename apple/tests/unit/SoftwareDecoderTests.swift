import VideoToolbox
import XCTest

@testable import RabbitEarsKit

/// Real devices advertise hardware decoders only; the Simulator has none, so it
/// offers H.264 in software for the server to convert to.
final class SoftwareDecoderTests: XCTestCase {
    func testOnlyTheSimulatorOffersSoftwareH264() throws {
        #if targetEnvironment(simulator)
            XCTAssertTrue(DeviceFacts.decoder.softwareH264)
            let decoder = CapabilitySnapshotBuilder.decoder(.decoder)
            let h264 = try XCTUnwrap(decoder.videoCodecs.first { $0.codec == "h264" })
            XCTAssertEqual(h264.hardware, VTIsHardwareDecodeSupported(kCMVideoCodecType_H264))
        #else
            XCTAssertFalse(DeviceFacts.decoder.softwareH264)
        #endif
    }

    func testSoftwareH264IsA1080pConversionTargetWithoutHardwareOrHDR() throws {
        let facts = DeviceFacts(
            hardwareVideoCodecs: [], hdrPlayback: true, audioDecoders: [], playableTypes: [],
            screen: nil, route: RouteFacts(channels: 2), path: PathFacts(), softwareH264: true)
        let codecs = CapabilitySnapshotBuilder.decoder(facts).videoCodecs
        XCTAssertEqual(codecs.count, 1)
        let h264 = try XCTUnwrap(codecs.first)
        XCTAssertEqual(h264.codec, "h264")
        XCTAssertFalse(h264.hardware)
        XCTAssertEqual(h264.maxWidth, 1920)
        XCTAssertEqual(h264.maxHeight, 1080)
        XCTAssertNil(h264.profiles)
        XCTAssertNil(h264.maxLevel)
        XCTAssertEqual(h264.maxBitDepth, 8)
        XCTAssertEqual(h264.hdrFormats, [])
    }

    func testNoHardwareAndNoSoftwareDecoderAdvertisesNone() {
        let facts = DeviceFacts(
            hardwareVideoCodecs: [], hdrPlayback: false, audioDecoders: [], playableTypes: [],
            screen: nil, route: RouteFacts(channels: 2), path: PathFacts())
        XCTAssertTrue(CapabilitySnapshotBuilder.decoder(facts).videoCodecs.isEmpty)
    }

    func testHardwareH264KeepsItsLimitsWithoutADuplicateSoftwareEntry() throws {
        let facts = DeviceFacts(
            hardwareVideoCodecs: ["h264"], hdrPlayback: false, audioDecoders: [], playableTypes: [],
            screen: nil, route: RouteFacts(channels: 2), path: PathFacts(), softwareH264: true)
        let codecs = CapabilitySnapshotBuilder.decoder(facts).videoCodecs
        XCTAssertEqual(codecs.count, 1)
        let h264 = try XCTUnwrap(codecs.first)
        XCTAssertTrue(h264.hardware)
        XCTAssertEqual(h264.maxWidth, 4096)
        XCTAssertEqual(h264.maxLevel, 52)
    }
}
