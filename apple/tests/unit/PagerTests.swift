import XCTest

@testable import RabbitEarsKit

@MainActor
final class PagerTests: XCTestCase {
    private var failing = true

    private func pager(pages: [Int?: ([Int], Int?)]) -> Pager<Int> {
        Pager { pages[$0] ?? ([], nil) }
    }

    func testLoadMoreFollowsNextOffsetUntilDone() async {
        let pager = pager(pages: [nil: ([1, 2], 2), 2: ([3], nil)])
        await pager.loadMore()
        XCTAssertEqual(pager.items, [1, 2])
        XCTAssertFalse(pager.done)
        await pager.loadMore()
        XCTAssertEqual(pager.items, [1, 2, 3])
        XCTAssertTrue(pager.done)
        await pager.loadMore()
        XCTAssertEqual(pager.items, [1, 2, 3])
    }

    func testLoadAllReadsEveryPage() async {
        let pager = pager(pages: [nil: ([1], 1), 1: ([2], 2), 2: ([3], nil)])
        await pager.loadAll()
        XCTAssertEqual(pager.items, [1, 2, 3])
        XCTAssertTrue(pager.done)
    }

    func testAFailedPageKeepsWhatLoadedAndRetries() async {
        let pager = Pager<Int> { [self] offset in
            if offset == 1, failing { throw AppError.server("down") }
            return offset == nil ? ([1], 1) : ([2], nil)
        }
        await pager.loadAll()
        XCTAssertEqual(pager.items, [1])
        XCTAssertEqual(pager.error, "down")
        XCTAssertFalse(pager.done)
        failing = false
        await pager.loadMore()
        XCTAssertEqual(pager.items, [1, 2])
        XCTAssertNil(pager.error)
        XCTAssertTrue(pager.done)
    }

    func testOverlappingLoadsFetchOnePage() async {
        var fetches = 0
        let pager = Pager<Int> { _ in
            fetches += 1
            try await Task.sleep(for: .milliseconds(20))
            return ([1], nil)
        }
        async let first: Void = pager.loadMore()
        async let second: Void = pager.loadMore()
        _ = await (first, second)
        XCTAssertEqual(fetches, 1)
        XCTAssertEqual(pager.items, [1])
    }

    func testRefreshRereadsEveryLoadedRowAndKeepsTheOldOnesUntilTheyArrive() async {
        var title = "old"
        var shown: [[String]] = []
        var pager: Pager<String>!
        pager = Pager { offset in
            shown.append(pager.items)
            switch offset {
            case nil: return (["a-\(title)", "b-\(title)"], 2)
            case 2: return (["c-\(title)", "d-\(title)"], 4)
            default: return (["e-\(title)"], nil)
            }
        }
        await pager.loadMore()
        await pager.loadMore()
        XCTAssertEqual(pager.items.count, 4)
        shown = []
        title = "new"
        await pager.refresh()
        XCTAssertEqual(pager.items, ["a-new", "b-new", "c-new", "d-new"])
        XCTAssertFalse(pager.done)
        let old = ["a-old", "b-old", "c-old", "d-old"]
        XCTAssertEqual(shown, [old, old])
        await pager.loadMore()
        XCTAssertEqual(pager.items.last, "e-new")
        XCTAssertTrue(pager.done)
    }

    func testRefreshOfAnUnloadedPagerReadsOnePage() async {
        let pager = pager(pages: [nil: ([1, 2], 2), 2: ([3], nil)])
        await pager.refresh()
        XCTAssertEqual(pager.items, [1, 2])
        XCTAssertFalse(pager.done)
    }

    func testAFailedRefreshKeepsTheRows() async {
        let pager = Pager<Int> { [self] _ in
            if !failing { return ([1, 2], nil) }
            throw AppError.server("down")
        }
        failing = false
        await pager.loadMore()
        failing = true
        await pager.refresh()
        XCTAssertEqual(pager.items, [1, 2])
        XCTAssertTrue(pager.done)
        XCTAssertNil(pager.error, "a quiet reload says nothing")
    }

    func testAFailedPullKeepsTheRowsSaysSoAndTryingAgainReadsThemAgain() async {
        let pager = Pager<Int> { [self] _ in
            if !failing { return ([1, 2], nil) }
            throw AppError.server("down")
        }
        failing = false
        await pager.loadMore()
        failing = true
        await pager.refresh(reporting: true)
        XCTAssertEqual(pager.items, [1, 2])
        XCTAssertEqual(pager.error, "down")

        failing = false
        await pager.loadMore()
        XCTAssertEqual(pager.items, [1, 2])
        XCTAssertNil(pager.error)
    }
}
