import XCTest

@testable import RabbitEarsKit

final class RepeatCycleTests: XCTestCase {
    func testRepeatCyclesOffAllOneOff() {
        XCTAssertEqual(RepeatMode.off.cycled, .all)
        XCTAssertEqual(RepeatMode.all.cycled, .one)
        XCTAssertEqual(RepeatMode.one.cycled, .off)
    }
}
