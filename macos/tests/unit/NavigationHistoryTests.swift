import AppKit
import XCTest

@testable import RabbitEarsKit

final class NavigationHistoryTests: XCTestCase {
    func testBackOffersForwardAndANewPageDropsIt() {
        var history = NavigationHistory<String>()
        XCTAssertFalse(history.canGoBack)
        history.path.append("Twister")
        history.path.append("Bill Paxton")
        history.back()
        XCTAssertEqual(history.path, ["Twister"])
        XCTAssertTrue(history.canGoForward)
        history.forward()
        XCTAssertEqual(history.path, ["Twister", "Bill Paxton"])
        XCTAssertFalse(history.canGoForward)
        history.back()
        history.path.append("Aliens")
        XCTAssertFalse(history.canGoForward, "a new page forgets the way forward")
    }

    func testThePathPoppedFromOutsideCanBeGoneForwardTo() {
        var history = NavigationHistory<String>()
        history.path = ["A", "B", "C"]
        history.path = ["A"]
        history.forward()
        history.forward()
        XCTAssertEqual(history.path, ["A", "B", "C"])
        history.path = ["X"]
        XCTAssertFalse(history.canGoForward)
        history.path = []
        history.reset()
        XCTAssertFalse(history.canGoForward)
    }

    func testReplacingThePageBacksOutToWhereItWasOpenedFrom() {
        var history = NavigationHistory<String>()
        history.path = ["Movies", "Fellowship", "Ian McKellen"]
        history.back()
        history.path.replaceTop(with: "Two Towers")
        XCTAssertEqual(history.path, ["Movies", "Two Towers"])
        XCTAssertFalse(history.canGoForward, "the replaced page's way forward is gone")
        history.back()
        XCTAssertEqual(history.path, ["Movies"])
    }

    func testBackIsLabelledWithThePageItReturnsTo() {
        var history = NavigationHistory<String>()
        XCTAssertNil(history.backTitle(root: "Movies"))
        history.path = ["twister"]
        XCTAssertEqual(history.backTitle(root: "Movies"), "Movies")
        history.titles["twister"] = "Twister"
        history.path.append("paxton")
        XCTAssertEqual(history.backTitle(root: "Movies"), "Twister")
        history.path.append("unnamed")
        XCTAssertEqual(history.backTitle(root: "Movies"), "Back")
    }
}

final class HistoryStepTests: XCTestCase {
    private func mouse(_ type: CGEventType, button: UInt32) throws -> NSEvent {
        let button = try XCTUnwrap(CGMouseButton(rawValue: button))
        let event = try XCTUnwrap(
            CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: .zero, mouseButton: button))
        return try XCTUnwrap(NSEvent(cgEvent: event))
    }

    func testMouseButtonsFourAndFiveGoBackAndForwardOnPress() throws {
        XCTAssertEqual(HistoryStep(try mouse(.otherMouseDown, button: 3)), .back)
        XCTAssertEqual(HistoryStep(try mouse(.otherMouseDown, button: 4)), .forward)
        XCTAssertNil(HistoryStep(try mouse(.otherMouseUp, button: 3)), "the release does not go twice")
        XCTAssertNil(HistoryStep(try mouse(.otherMouseDown, button: 2)), "the wheel button is not history")
    }

    func testAStepMovesTheHistory() {
        var history = NavigationHistory<String>()
        history.path = ["A", "B"]
        history.take(.back)
        XCTAssertEqual(history.path, ["A"])
        history.take(.forward)
        XCTAssertEqual(history.path, ["A", "B"])
    }
}
