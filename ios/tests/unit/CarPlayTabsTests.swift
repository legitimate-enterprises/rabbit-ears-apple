import XCTest

@testable import RabbitEarsKit

/// The server going away takes over the whole car only when no tab has anything to show.
final class CarPlayTabsTests: XCTestCase {
    func testOneTabWithNothingLeavesTheOthersShowing() {
        var tabs = CarPlayTabs(["recent", "albums", "artists"])
        tabs.answered("recent", rows: true)
        tabs.unreachable("albums")
        tabs.unreachable("artists")
        XCTAssertFalse(tabs.nothingAnywhere, "Recent still shows what is kept")
    }

    func testEveryTabWithNothingTakesOverTheWholeCar() {
        var tabs = CarPlayTabs(["recent", "albums", "playlists"])
        tabs.unreachable("recent")
        XCTAssertFalse(tabs.nothingAnywhere, "the others have not answered yet")
        tabs.answered("playlists", rows: false)
        tabs.unreachable("albums")
        XCTAssertTrue(tabs.nothingAnywhere)
    }

    func testEmptyTabsWithTheServerThereAreNotTheServerGone() {
        var tabs = CarPlayTabs(["recent", "albums"])
        tabs.answered("recent", rows: false)
        tabs.answered("albums", rows: false)
        XCTAssertFalse(tabs.nothingAnywhere)
    }

    func testATabThatAnswersAgainCounts() {
        var tabs = CarPlayTabs(["recent", "albums"])
        tabs.unreachable("recent")
        tabs.unreachable("albums")
        XCTAssertTrue(tabs.nothingAnywhere)
        tabs.answered("albums", rows: true)
        XCTAssertFalse(tabs.nothingAnywhere)
        tabs.answered("elsewhere", rows: true)
        XCTAssertFalse(tabs.nothingAnywhere, "a list that is not a tab changes nothing")
    }
}
