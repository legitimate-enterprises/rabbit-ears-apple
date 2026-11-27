import Foundation
import RabbitEarsAPI
import XCTest

@testable import RabbitEarsKit

@MainActor
final class TVCapabilitiesTests: XCTestCase {
    func testAnHDRDisplayAdvertisesEveryHDRFormat() {
        let uhd = SystemCapabilities.screenFacts(
            nativeSize: CGSize(width: 3840, height: 2160), refreshRate: 60, hdr: true)
        let display = CapabilitySnapshotBuilder.display(uhd)
        XCTAssertEqual([display.width, display.height], [3840, 2160])
        XCTAssertEqual(display.hdrFormats, [.hdr10, .hlg, .dolbyVision])
        let sdr = SystemCapabilities.screenFacts(
            nativeSize: CGSize(width: 1920, height: 1080), refreshRate: 50, hdr: false)
        XCTAssertEqual(CapabilitySnapshotBuilder.display(sdr).hdrFormats, [])
        XCTAssertEqual(CapabilitySnapshotBuilder.display(sdr).refreshRate, 50)
    }

    func testAReceiverShowsAsItsChannels() {
        let route = CapabilitySnapshotBuilder.audioRoute(SystemCapabilities.routeFacts(channels: 8, sampleRate: 48000))
        XCTAssertEqual(route.channels, 8)
        XCTAssertEqual(route.passthroughCodecs, [])
        XCTAssertEqual(route.maxSampleRate, 48000)
    }

    func testTheLiveReaderAnswersWithoutAScreen() {
        let facts = SystemCapabilities().facts()
        XCTAssertGreaterThanOrEqual(facts.route.channels, 1)
        XCTAssertFalse(facts.model.isEmpty)
        XCTAssertEqual(CapabilitySnapshotBuilder.decoder(facts).protocols, [.http, .hls])
    }

    func testAReleasedReaderDeinitializes() {
        weak var released: SystemCapabilities?
        do {
            let reader = SystemCapabilities()
            released = reader
        }
        XCTAssertNil(released)
    }
}
