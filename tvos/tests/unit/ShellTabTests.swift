import XCTest

@testable import RabbitEarsKit

/// Every profile sees every section, since the server filters what a kid may see.
final class ShellTabTests: XCTestCase {
    func testEverySectionInBarOrder() {
        XCTAssertEqual(ShellTab.allCases, [.home, .tv, .movies, .music, .youTube, .search])
        XCTAssertEqual(ShellTab.allCases.map(\.title), ["Home", "TV", "Movies", "Music", "YouTube", "Search"])
    }
}
