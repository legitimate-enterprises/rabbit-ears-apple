import Foundation
import RabbitEarsAPI
import XCTest

@testable import RabbitEarsKit

final class ItemMenuActionsTests: XCTestCase {
    func testAnAdultRulesAMovieAndAShowOnly() {
        for kind in [ItemKind.movie, .show] {
            let actions = ItemMenuActions(kind: kind, adult: true, allowListKids: true)
            XCTAssertTrue(actions.kidsRules, "\(kind)")
            XCTAssertTrue(actions.allowList, "\(kind)")
        }
        for kind in [ItemKind.season, .episode] {
            let actions = ItemMenuActions(kind: kind, adult: true, allowListKids: true)
            XCTAssertFalse(actions.kidsRules, "\(kind) follows its show")
            XCTAssertFalse(actions.allowList, "\(kind) follows its show")
        }
    }

    func testTheAllowListNeedsAKidOnOne() {
        let actions = ItemMenuActions(kind: .movie, adult: true, allowListKids: false)
        XCTAssertTrue(actions.kidsRules)
        XCTAssertFalse(actions.allowList)
    }

    func testAnAdultAddsAnyKindAndOnlyAMovieToACollection() {
        XCTAssertEqual(
            [ItemKind.movie, .show, .season, .episode].map {
                ItemMenuActions(kind: $0, adult: true, allowListKids: false).addToCollection
            }, [true, false, false, false])
        XCTAssertTrue(ItemMenuActions(kind: .episode, adult: true, allowListKids: false).addTo)
    }

    func testAKidGetsNoRulesAndNoAdding() {
        for kind in [ItemKind.movie, .show, .season, .episode] {
            let actions = ItemMenuActions(kind: kind, adult: false, allowListKids: true)
            XCTAssertEqual(
                [actions.kidsRules, actions.allowList, actions.addTo, actions.addToCollection],
                [false, false, false, false], "\(kind)")
        }
    }
}
