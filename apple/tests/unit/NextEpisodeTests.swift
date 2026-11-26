import Foundation
import RabbitEarsAPI
import XCTest

@testable import RabbitEarsKit

@MainActor
private final class Shelf: VideoBrowser {
    var playing: PlayRequest?
}

@MainActor
final class NextEpisodeTests: XCTestCase {
    let second = Fixtures.decode(Fixtures.item(22, "episode", "Second"), as: Item.self)

    func testTheNextEpisodePlaysFromTheStartInTheOpenCover() {
        let shelf = Shelf()
        let pilot = PlayRequest(
            item: Fixtures.decode(Fixtures.item(21, "episode", "Pilot"), as: Item.self), positionMs: 600_000)
        shelf.playing = pilot
        shelf.playNext(second)
        XCTAssertEqual(shelf.playing?.id, pilot.id)
        XCTAssertEqual(shelf.playing?.item.id, 22)
        XCTAssertEqual(shelf.playing?.positionMs, 0)
    }

    func testWithNothingOpenItOpensAPlayer() {
        let shelf = Shelf()
        shelf.playNext(second)
        XCTAssertEqual(shelf.playing?.item.id, 22)
    }
}
