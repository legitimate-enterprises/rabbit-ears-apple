import XCTest

@testable import RabbitEarsKit

final class ControlsFadeTests: XCTestCase {
    func testFadeStartsSoonerAndEndsWhenTheControlsUsedToVanish() {
        XCTAssertEqual(ControlsFade.delay, 2)
        XCTAssertEqual(ControlsFade.remoteDelay, 3)
        XCTAssertEqual(ControlsFade.fade, 1)
        XCTAssertEqual(ControlsFade.delay + ControlsFade.fade, 3)
        XCTAssertEqual(ControlsFade.remoteDelay + ControlsFade.fade, 4)
    }
}
