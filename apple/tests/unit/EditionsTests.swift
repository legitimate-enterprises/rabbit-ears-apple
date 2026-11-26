import Foundation
import RabbitEarsAPI
import XCTest

@testable import RabbitEarsKit

final class EditionsTests: XCTestCase {
    let editions = [
        Fixtures.edition(5, "Standard", isDefault: true, runtimeMs: 8_280_000),
        Fixtures.edition(6, "Extended", runtimeMs: 13_680_000, qualities: ["4K", "1080p", "1080p"]),
    ]
    .map { Fixtures.decode($0, as: Edition.self) }

    private func watch(position: Int64 = 600_000, watched: Bool = false, edition: Int64?) -> WatchState {
        Fixtures.decode(Fixtures.watch(20, position: position, watched: watched, edition: edition))
    }

    func testThePositionsEditionIsPreselectedElseTheDefault() {
        XCTAssertEqual(Editions.preselected(editions, watch: watch(edition: 6))?.id, 6)
        XCTAssertEqual(Editions.preselected(editions, watch: watch(edition: 5))?.id, 5)
        XCTAssertEqual(Editions.preselected(editions, watch: nil)?.id, 5)
        XCTAssertEqual(
            Editions.preselected(editions, watch: watch(edition: 99))?.id, 5, "an edition gone from the list")
        XCTAssertEqual(
            Editions.preselected(editions, watch: watch(position: 0, watched: true, edition: 6))?.id, 5,
            "nothing to resume")
        XCTAssertEqual(Editions.preselected(editions, watch: watch(watched: true, edition: 6))?.id, 6, "a rewatch")
        XCTAssertEqual(Editions.preselected(editions.reversed(), watch: nil)?.id, 5, "the default wherever it is")
        XCTAssertNil(Editions.preselected([], watch: watch(edition: 6)))
    }

    func testResumeIsOfferedOnlyForTheEditionHoldingThePosition() {
        XCTAssertTrue(Editions.resumes(editions[1], watch: watch(edition: 6)))
        XCTAssertFalse(Editions.resumes(editions[0], watch: watch(edition: 6)))
        XCTAssertFalse(Editions.resumes(editions[0], watch: watch(edition: nil)), "the server resumes no edition")
        XCTAssertFalse(Editions.resumes(editions[1], watch: watch(position: 0, edition: 6)))
        XCTAssertTrue(Editions.resumes(editions[1], watch: watch(watched: true, edition: 6)), "a rewatch")
        XCTAssertFalse(Editions.resumes(editions[1], watch: nil))
        XCTAssertTrue(Editions.resumes(nil, watch: watch(edition: 6)), "editions not read yet: as before")
    }

    func testTheLabelNamesTheCutItsRuntimeAndEachQualityOnce() {
        XCTAssertEqual(Editions.label(editions[1]), "Extended · 3h 48m · 4K, 1080p")
        XCTAssertEqual(Editions.label(editions[0]), "Standard · 2h 18m · 1080p")
        let bare = Fixtures.decode(Fixtures.edition(7, "Workprint", qualities: []), as: Edition.self)
        XCTAssertEqual(Editions.label(bare), "Workprint")
    }

    func testAnEditionIsSentOnlyWhenThereIsAChoiceAndNotTogether() {
        XCTAssertEqual(Editions.sent(editions[1], of: editions, together: false), 6)
        XCTAssertNil(Editions.sent(editions[1], of: editions, together: true))
        XCTAssertNil(Editions.sent(editions[0], of: [editions[0]], together: false))
        XCTAssertNil(Editions.sent(nil, of: editions, together: false))
    }

    func testAResumeFromHomeNamesThePositionsEdition() {
        let items = [Fixtures.item(20, "movie", "Ferrous Tide"), Fixtures.item(21, "movie", "Paper Moons")]
            .map { Fixtures.decode($0, as: Item.self) }
        let catalog = Catalog(
            items: items,
            watch: [
                Fixtures.watch(20, position: 600_000, edition: 6),
                Fixtures.watch(21, position: 0, watched: true, edition: 8),
            ]
            .map { Fixtures.decode($0, as: WatchState.self) })
        XCTAssertEqual(catalog.resumeEdition(20), 6)
        XCTAssertNil(catalog.resumeEdition(21), "nothing to resume")
        XCTAssertNil(catalog.resumeEdition(22))

        XCTAssertEqual(Editions.started(.none, item: 20, in: catalog, together: false), 6, "from Home: the position's")
        XCTAssertNil(Editions.started(.none, item: 20, in: catalog, together: true), "Watch together: the default")
        XCTAssertNil(Editions.started(.some(nil), item: 20, in: catalog, together: false), "details chose the default")
        XCTAssertEqual(Editions.started(.some(5), item: 20, in: catalog, together: false), 5, "details chose one")
        XCTAssertNil(Editions.started(.none, item: 21, in: catalog, together: false))
    }

    @MainActor
    func testDetailsReadTheEditionsPreselectAndDescribeTheChosenCopy() async throws {
        func file(_ id: Int64) -> String {
            #"{"id":\#(id),"itemId":20,"path":"/media/f\#(id).mkv","sizeBytes":1,"modifiedAt":"2026-01-01T00:00:00Z","#
                + #""chapters":[],"tracks":[]}"#
        }
        let item = String(Fixtures.item(20, "movie", "Ferrous Tide").dropLast())
        let transport = RoutingTransport([
            "GET /items": (.ok, Fixtures.page([Fixtures.item(20, "movie", "Ferrous Tide")])),
            "GET /profiles/1/watch-state": (.ok, Fixtures.page([Fixtures.watch(20, position: 600_000, edition: 6)])),
            "GET /items/20": (
                .ok,
                item + #","editions":[\#(Fixtures.edition(5, "Standard", isDefault: true)),"#
                    + #"\#(Fixtures.edition(6, "Extended"))]}"#
            ),
            "GET /media-files": (.ok, Fixtures.page([file(50), file(60)])),
        ])
        let model = CatalogModel(
            client: ServerEndpoint(userInput: "192.168.1.9")!.client(token: "t", transport: transport), profileId: 1)
        await model.load()
        let choice = EditionChoice()
        XCTAssertEqual(choice.sent(together: false), .none, "unread: the start resumes the position's edition")
        await choice.load(20, from: model)
        XCTAssertTrue(choice.offered)
        XCTAssertEqual(choice.editionId, 6)
        XCTAssertEqual(choice.file?.id, 60)
        XCTAssertTrue(choice.resumes(model.catalog.watch[20]))
        XCTAssertEqual(choice.sent(together: false), .some(6))
        XCTAssertEqual(choice.sent(together: true), .some(nil))
        choice.editionId = 5
        XCTAssertEqual(choice.file?.id, 50)
        XCTAssertFalse(choice.resumes(model.catalog.watch[20]))
    }
}
