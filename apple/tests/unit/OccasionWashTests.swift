import Foundation
import XCTest

@testable import RabbitEarsKit

final class OccasionWashTests: XCTestCase {
    func testAHexColourReadsAsItsThreeChannels() throws {
        let red = try XCTUnwrap(OccasionWash.rgb("#C8102E"))
        XCTAssertEqual(red.red, 200.0 / 255, accuracy: 0.0001)
        XCTAssertEqual(red.green, 16.0 / 255, accuracy: 0.0001)
        XCTAssertEqual(red.blue, 46.0 / 255, accuracy: 0.0001)
        XCTAssertNotNil(OccasionWash.rgb("#abcdef"))
    }

    func testAnythingButSixHexDigitsAfterAHashIsNotAColour() {
        for bad in ["C8102E", "#C8102", "#C8102E0", "#GG0000", "", "#12345Z", "#+12345"] {
            XCTAssertNil(OccasionWash.rgb(bad), bad)
        }
    }

    func testTheWashNeedsAllThreeColoursToShow() {
        XCTAssertEqual(OccasionWash.palette(["#C8102E", "#00843D", "#FFD100"])?.count, 3)
        XCTAssertNil(OccasionWash.palette(["#C8102E", "#00843D"]))
        XCTAssertNil(OccasionWash.palette([]))
        XCTAssertNil(OccasionWash.palette(nil))
        XCTAssertNil(OccasionWash.palette(["#C8102E", "#00843D", "nope"]))
    }

    private let christmas = OccasionWash.palette(["#1F6B45", "#B3263E", "#E0B252"])!

    /// The web's wash test: each color brightened, at its corner of a triangle pointing down.
    func testEachColorIsBrightenedAndGlowsFromItsCornerOfTheTriangle() {
        let glows = OccasionWash.glows(christmas, .init(strength: 200, brightness: 15, sharpness: 0, reach: 100))
        XCTAssertEqual(glows.map(\.center), [.topLeading, .bottom, .topTrailing])
        assertGlow(glows[0], rgb: [65, 129, 97], stops: [(0.48, 0), (0.48, 0), (0.192, 0.5), (0, 1)])
        assertGlow(glows[1], rgb: [190, 71, 91], stops: [(0.6, 0), (0.6, 0), (0.24, 0.5), (0, 1)])
        assertGlow(glows[2], rgb: [229, 190, 108], stops: [(0.48, 0), (0.48, 0), (0.192, 0.5), (0, 1)])
    }

    func testThePeakIsCappedAtOneAndHeldToTheSharpness() {
        let glows = OccasionWash.glows(christmas, .init(strength: 400, brightness: 0, sharpness: 40, reach: 140))
        assertGlow(glows[0], rgb: [31, 107, 69], stops: [(0.96, 0), (0.96, 0.4), (0.384, 0.7), (0, 1)])
        assertGlow(glows[1], rgb: [179, 38, 62], stops: [(1, 0), (1, 0.4), (0.4, 0.7), (0, 1)])
    }

    func testTheRadiusIsTheLargerOfTheWidthsAndHeightsShareScaledByTheReach() {
        XCTAssertEqual(OccasionWash.radius(in: CGSize(width: 1000, height: 3000), reach: 100), 1500, accuracy: 0.001)
        XCTAssertEqual(OccasionWash.radius(in: CGSize(width: 3000, height: 1000), reach: 100), 2400, accuracy: 0.001)
        XCTAssertEqual(OccasionWash.radius(in: CGSize(width: 1000, height: 3000), reach: 140), 2100, accuracy: 0.001)
        XCTAssertEqual(OccasionWash.radius(in: CGSize(width: 3000, height: 1000), reach: 60), 1440, accuracy: 0.001)
    }

    private func assertGlow(
        _ glow: OccasionWash.Glow, rgb: [Double], stops: [(Double, Double)], line: UInt = #line
    ) {
        let color = glow.color
        for (got, want) in zip([color.red, color.green, color.blue], rgb) {
            XCTAssertEqual(got * 255, want, accuracy: 0.5, "channel", line: line)
        }
        XCTAssertEqual(glow.stops.count, stops.count, line: line)
        for (got, want) in zip(glow.stops, stops) {
            XCTAssertEqual(got.opacity, want.0, accuracy: 0.0001, "opacity", line: line)
            XCTAssertEqual(got.location, want.1, accuracy: 0.0001, "location", line: line)
        }
    }
}
