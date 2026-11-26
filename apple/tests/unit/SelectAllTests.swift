import XCTest

@testable import RabbitEarsKit

/// Select all over a paged listing: every page of the filtered set, not only what has scrolled in.
@MainActor
final class SelectAllTests: XCTestCase {
    /// `pages` pages of three ids, 1 up; a page takes `wait` to arrive.
    private func pager(pages: Int, wait: Duration = .zero, failingAt: Int? = nil) -> Pager<Int64> {
        Pager { offset in
            let start = offset ?? 0
            if wait > .zero { try await Task.sleep(for: wait) }
            if start == failingAt { throw AppError.server("down") }
            let next = start + 3
            return ((start..<next).map { Int64($0 + 1) }, next < pages * 3 ? next : nil)
        }
    }

    private func selecting(_ pager: Pager<Int64>) -> Selection {
        let selection = Selection()
        selection.begin()
        selection.source = .init({ pager }, id: { $0 })
        return selection
    }

    func testSelectAllReadsTheRemainingPagesAndPicksExactlyTheFullSet() async {
        let pager = pager(pages: 4)
        await pager.loadMore()
        let selection = selecting(pager)
        selection.toggleAll()
        XCTAssertTrue(selection.gathering)
        await selection.gather?.value
        XCTAssertEqual(selection.picked, Set(1...12))
        XCTAssertEqual(selection.inPickOrder, Array(1...12))
        XCTAssertFalse(selection.gathering)
        XCTAssertTrue(selection.allPicked)
    }

    func testDeselectAllEmptiesTheSelectionAndStaysInSelectionMode() async {
        let pager = pager(pages: 3)
        let selection = selecting(pager)
        selection.toggleAll()
        await selection.gather?.value
        selection.toggleAll()
        XCTAssertEqual(selection.count, 0)
        XCTAssertTrue(selection.inPickOrder.isEmpty)
        XCTAssertTrue(selection.active)
        XCTAssertFalse(selection.allPicked)
    }

    func testSomePickedIsNotAllPickedUntilEveryPageIsRead() async {
        let pager = pager(pages: 2)
        await pager.loadMore()
        let selection = selecting(pager)
        selection.selectAll([1, 2, 3])
        XCTAssertFalse(selection.allPicked, "the second page has not been read")
        selection.toggleAll()
        await selection.gather?.value
        XCTAssertEqual(selection.picked, Set(1...6))
    }

    func testAHeldListingIsPickedWholeWithoutReadingAnything() async {
        let selection = Selection()
        selection.begin()
        selection.source = .init { [5, 3, 9] }
        selection.toggleAll()
        await selection.gather?.value
        XCTAssertEqual(selection.inPickOrder, [5, 3, 9])
        XCTAssertFalse(selection.gathering)
        selection.toggleAll()
        XCTAssertEqual(selection.count, 0)
    }

    func testDoneWhileReadingStopsItAndPicksNothing() async throws {
        let pager = pager(pages: 50, wait: .milliseconds(20))
        let selection = selecting(pager)
        selection.toggleAll()
        try await Task.sleep(for: .milliseconds(50))
        let task = try XCTUnwrap(selection.gather)
        selection.end()
        await task.value
        XCTAssertFalse(selection.active)
        XCTAssertFalse(selection.gathering)
        XCTAssertEqual(selection.count, 0)
        XCTAssertNil(pager.error, "a cancelled page is not a failure")
        XCTAssertFalse(pager.done)
    }

    func testAFailedPageLeavesNothingPicked() async {
        let pager = pager(pages: 3, failingAt: 3)
        let selection = selecting(pager)
        selection.toggleAll()
        await selection.gather?.value
        XCTAssertEqual(pager.error, "down")
        XCTAssertEqual(selection.count, 0)
    }

    func testAScrollLoadInFlightIsWaitedForNotSkipped() async {
        let pager = pager(pages: 3, wait: .milliseconds(20))
        let scrolling = Task { await pager.loadMore() }
        await Task.yield()
        await pager.loadAll()
        await scrolling.value
        XCTAssertEqual(pager.items.count, 9)
        XCTAssertTrue(pager.done)
    }
}
