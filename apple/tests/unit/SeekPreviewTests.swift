import Foundation
import RabbitEarsAPI
import XCTest

@testable import RabbitEarsKit

final class SeekPreviewTests: XCTestCase {
    let frames = PreviewFrames(
        intervalMs: 10_000, count: 100, width: 320, height: 180,
        frameUrl: "/api/v2/streams/k1/0/previews/{n}.jpg", bifUrl: "/api/v2/streams/k1/0/previews.bif")

    func testTheFrameIsTheOneNearestThePosition() {
        XCTAssertEqual(frames.index(at: 0), 0)
        XCTAssertEqual(frames.index(at: 4.9), 0)
        XCTAssertEqual(frames.index(at: 5), 1)
        XCTAssertEqual(frames.index(at: 604), 60)
    }

    func testPositionsOutsideTheFramesClampToTheEnds() {
        XCTAssertEqual(frames.index(at: -3), 0)
        XCTAssertEqual(frames.index(at: .nan), 0)
        XCTAssertEqual(frames.index(at: 99_999), 99)
    }

    func testTheFrameURLFillsTheIndexAndResolvesAgainstTheServer() {
        let server = ServerEndpoint(userInput: "192.168.1.9")!
        XCTAssertEqual(
            frames.url(at: 604, endpoint: server).absoluteString,
            "http://192.168.1.9:8477/api/v2/streams/k1/0/previews/60.jpg")
    }

    func testAPointerPositionMapsToATimeWithinTheRuntime() {
        XCTAssertEqual(Scrub.seconds(atX: 250, width: 1000, duration: 2880), 720)
        XCTAssertEqual(Scrub.seconds(atX: -20, width: 1000, duration: 2880), 0)
        XCTAssertEqual(Scrub.seconds(atX: 1500, width: 1000, duration: 2880), 2880)
        XCTAssertEqual(Scrub.seconds(atX: 10, width: 0, duration: 2880), 0)
    }

    func testTheCardStaysInsideTheBar() {
        XCTAssertEqual(Scrub.cardCenter(atX: 500, width: 1000, card: 260), 500)
        XCTAssertEqual(Scrub.cardCenter(atX: 20, width: 1000, card: 260), 130)
        XCTAssertEqual(Scrub.cardCenter(atX: 990, width: 1000, card: 260), 870)
        XCTAssertEqual(Scrub.cardCenter(atX: 50, width: 200, card: 260), 100)
    }
}
