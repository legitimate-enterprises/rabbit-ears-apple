import RabbitEarsAPI
import XCTest

@testable import RabbitEarsKit

final class MusicRemoteTests: XCTestCase {
    func testRepeatOneSaysSo() {
        XCTAssertEqual(RepeatMode.one.label, "Repeat one")
    }
}
