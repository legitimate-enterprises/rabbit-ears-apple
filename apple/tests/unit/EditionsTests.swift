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

    /// Dune (20) has two untagged cuts with files, one tagged, and one with
    /// none; Kit (3), a kid to PG, may not see it.
    private func dune(missingFirstCut: Bool = false) throws -> Replica {
        let fixture = ReplicaFixture()
        addTeardownBlock { fixture.remove() }
        return try fixture.v1 { db in
            try db.account(1, "Avery")
            try db.account(3, "Kit", kind: "kid", movies: "PG")
            try db.item(20, "movie", "Dune", rating: "PG-13")
            try db.edition(5, of: 20, runtimeMs: 8_280_000)
            try db.file(50, in: 5, width: 1920, height: 1080, missing: missingFirstCut)
            try db.edition(6, of: 20, tag: "Extended")
            try db.file(61, in: 6, width: 1280, height: 720, size: 9000, durationMs: 13_680_000, missing: true)
            try db.file(60, in: 6, width: 3840, height: 2160, hdr: "dolby_vision", size: 10, durationMs: 13_000_000)
            try db.edition(7, of: 20, runtimeMs: 7_000_000)
            try db.file(70, in: 7)
            try db.edition(8, of: 20, tag: "Workprint")
        }
    }

    @MainActor
    func testEditionsAreNamedTheDefaultFirstThenByNameEachCopyTallestFirst() async throws {
        let replica = try dune()
        let editions = await CatalogModel(
            client: ServerEndpoint.default.client(token: "t"), replica: replica, profileId: 1
        )
        .editions(20)
        XCTAssertEqual(editions.map(\.id), [5, 7, 6], "Workprint has no file")
        XCTAssertEqual(editions.map(\.name), ["138-minute cut", "117-minute cut", "Extended"])
        XCTAssertEqual(editions.map(\.isDefault), [true, false, false])
        XCTAssertEqual(editions.map(\.runtimeMs), [8_280_000, 7_000_000, 13_680_000], "else its largest file's")
        let extended = editions[2].copies
        XCTAssertEqual(extended.map(\.mediaFileId), [60, 61])
        XCTAssertEqual(extended.map(\.quality), ["4K", "720p"])
        XCTAssertEqual(extended.map(\.hdrFormat), [.dolbyVision, nil])
        XCTAssertEqual(extended.map(\.unavailable), [nil, true])
        XCTAssertEqual(editions[1].copies.map(\.quality), [nil], "no video")
        XCTAssertEqual(Editions.label(editions[0]), "138-minute cut · 2h 18m · 1080p")

        let kid = await CatalogModel(client: ServerEndpoint.default.client(token: "t"), replica: replica, profileId: 3)
            .editions(20)
        XCTAssertEqual(kid, [])
    }

    @MainActor
    func testTheDefaultIsTheFirstUntaggedCutWithAFileOnDisk() async throws {
        let editions = await CatalogModel(
            client: ServerEndpoint.default.client(token: "t"), replica: try dune(missingFirstCut: true), profileId: 1
        ).editions(20)
        XCTAssertEqual(editions.map(\.id), [7, 5, 6])
        XCTAssertEqual(editions.first?.isDefault, true)
    }

    @MainActor
    func testDetailsReadTheEditionsPreselectAndDescribeTheChosenCopy() async throws {
        func file(_ id: Int64) -> String {
            #"{"id":\#(id),"itemId":20,"path":"/media/f\#(id).mkv","sizeBytes":1,"modifiedAt":"2026-01-01T00:00:00Z","#
                + #""chapters":[],"tracks":[]}"#
        }
        let transport = RoutingTransport(["GET /media-files": (.ok, Fixtures.page([file(50), file(60)]))])
        let replica = try dune()
        try await replica.write { try $0.watch(20, for: 1, position: 600_000, edition: 6) }
        let model = CatalogModel(
            client: ServerEndpoint(userInput: "192.168.1.9")!.client(token: "t", transport: transport),
            replica: replica, profileId: 1)
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
