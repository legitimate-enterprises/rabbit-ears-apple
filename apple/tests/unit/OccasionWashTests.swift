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
}
