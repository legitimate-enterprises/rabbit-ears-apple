import Foundation
import RabbitEarsAPI
import XCTest

@testable import RabbitEarsKit

final class PlayerCatalogTests: XCTestCase {
    func testAFinaleHasNoNextEpisodeAndSpecialsStepThroughSpecials() {
        let catalog = Catalog(
            items: [
                Fixtures.item(10, "show", "Severance"),
                Fixtures.item(11, "season", "Season 1", parent: 10, season: 1),
                Fixtures.item(13, "season", "Specials", parent: 10, season: 0),
                Fixtures.item(101, "episode", "Good News", parent: 11, season: 1, episode: 1),
                Fixtures.item(102, "episode", "Half Loop", parent: 11, season: 1, episode: 2),
                Fixtures.item(301, "episode", "Inside", parent: 13, season: 0, episode: 1),
                Fixtures.item(302, "episode", "Outside", parent: 13, season: 0, episode: 2),
            ].map { Fixtures.decode($0, as: Item.self) }, watch: [])
        func next(_ id: Item.ID) -> Item.ID? { catalog.item(id).flatMap(catalog.nextEpisode(after:))?.id }
        XCTAssertEqual(next(101), 102)
        XCTAssertNil(next(102))
        XCTAssertEqual(next(301), 302)
        XCTAssertEqual(catalog.playerTitle(catalog.item(101)!, edition: nil), "Severance")
        XCTAssertEqual(Catalog.playerSubtitle(catalog.item(101)!), "S1 E1 · Good News")
    }
}
