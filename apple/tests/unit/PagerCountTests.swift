import XCTest

@testable import RabbitEarsKit

private struct Counted: CountedPage {
    let items: [Int]
    let nextOffset: Int?
    let total: Int
}

@MainActor
final class PagerCountTests: XCTestCase {
    func testACountedPagerKnowsItsTotalFromTheFirstPage() async {
        let pager = Pager<Int>(counted: { offset in
            offset == nil
                ? Counted(items: [1, 2], nextOffset: 2, total: 5)
                : Counted(items: [3, 4, 5], nextOffset: nil, total: 5)
        })
        await pager.loadMore()
        XCTAssertEqual(pager.items.count, 2)
        XCTAssertEqual(pager.countText, "5")
        XCTAssertEqual(pager.count, 5)
        XCTAssertTrue(pager.countIsExact)
        await pager.loadMore()
        XCTAssertEqual(pager.countText, "5")
    }

    func testTheTotalFollowsARefresh() async {
        var total = 5
        let pager = Pager<Int>(counted: { _ in Counted(items: [1], nextOffset: nil, total: total) })
        await pager.loadMore()
        total = 1_210
        await pager.refresh()
        XCTAssertEqual(pager.countText, "1,210")
    }

    func testAPagerWithoutATotalCountsWhatIsLoadedAndSaysMoreIsToCome() async {
        let pager = Pager<Int> { $0 == nil ? ([1, 2], 2) : ([3], nil) }
        await pager.loadMore()
        XCTAssertEqual(pager.countText, "2+")
        XCTAssertFalse(pager.countIsExact)
        await pager.loadMore()
        XCTAssertEqual(pager.countText, "3")
        XCTAssertTrue(pager.countIsExact)
    }
}
