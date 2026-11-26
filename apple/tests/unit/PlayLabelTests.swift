import RabbitEarsAPI
import XCTest

@testable import RabbitEarsKit

final class PlayLabelTests: XCTestCase {
    func testATileThatPlaysAtOnceSaysSo() {
        let items = [
            Fixtures.item(10, "show", "Severance", added: "2026-03-01T00:00:00Z"),
            Fixtures.item(11, "season", "Season 1", parent: 10, season: 1),
            Fixtures.item(102, "episode", "Half Loop", parent: 11, season: 1, episode: 2),
            Fixtures.item(20, "movie", "Dune", added: "2026-02-01T00:00:00Z"),
        ].map { Fixtures.decode($0, as: Item.self) }
        let catalog = Catalog(items: items, watch: [])
        XCTAssertEqual(EpisodeText.playLabel(catalog.item(102)!, catalog), "Play Severance, S1 E2 Half Loop")
        XCTAssertEqual(EpisodeText.playLabel(catalog.item(20)!, catalog), "Play Dune")
    }
}
