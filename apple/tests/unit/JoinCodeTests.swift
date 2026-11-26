import XCTest

@testable import RabbitEarsKit

final class JoinCodeTests: XCTestCase {
    func testNormalizesCaseAndDash() {
        XCTAssertEqual(JoinCode.normalize("7kq4mnp2"), "7KQ4-MNP2")
        XCTAssertEqual(JoinCode.normalize(" 7KQ4-mnp2 "), "7KQ4-MNP2")
    }

    func testRejectsLettersOutsideTheAlphabet() {
        XCTAssertNil(JoinCode.normalize("7KQ4-MNP0"))
        XCTAssertNil(JoinCode.normalize("OKQ4-MNP2"))
        XCTAssertNil(JoinCode.normalize("7KQ4-MNP"))
    }

    func testReadsAJoinLink() throws {
        let link = try XCTUnwrap(JoinCode.parseLink("https://media.example.test/join/7kq4-mnp2"))
        XCTAssertEqual(link.server.baseURL.absoluteString, "https://media.example.test")
        XCTAssertEqual(link.code, "7KQ4-MNP2")
        XCTAssertNil(JoinCode.parseLink("7KQ4-MNP2"))
    }
}
