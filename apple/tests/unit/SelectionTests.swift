import GRDB
import RabbitEarsAPI
import XCTest

@testable import RabbitEarsKit

@MainActor
final class SelectionTests: XCTestCase {
    func testClickTogglesShiftClickTakesTheRangeAndSelectAllTakesEveryOne() {
        let selection = Selection()
        let order: [UID] = [5, 4, 3, 2, 1]
        selection.begin()
        selection.toggle(4)
        selection.extend(to: 2, in: order)
        XCTAssertEqual(selection.ordered(order), [4, 3, 2])
        selection.toggle(3)
        XCTAssertEqual(selection.ordered(order), [4, 2])
        selection.extend(to: 5, in: order)
        XCTAssertEqual(selection.ordered(order), [5, 4, 3, 2])
        selection.selectAll(order)
        XCTAssertEqual(selection.count, 5)
        selection.end()
        XCTAssertFalse(selection.active)
        XCTAssertEqual(selection.count, 0)
    }

    func testATapOrderIsKeptForAddingInThatOrder() {
        let selection = Selection()
        selection.toggle(3)
        selection.toggle(1)
        selection.toggle(2)
        selection.toggle(3)
        XCTAssertEqual(selection.inPickOrder, [1, 2])
    }

    func testNothingFromYouTubeGoesInAPlaylistAndMusicIsNeverWatched() {
        XCTAssertNil(SelectKind.channel.playlistKind)
        XCTAssertNil(SelectKind.video.playlistKind)
        XCTAssertEqual(SelectKind.show.playlistKind, .tv)
        XCTAssertEqual(SelectKind.song.playlistKind, .music)
        XCTAssertFalse(SelectKind.album.watches)
        XCTAssertFalse(SelectKind.video.kidsContent)
    }

    func testAShiftClickWithNoAnchorIsAClick() {
        let selection = Selection()
        selection.begin()
        selection.extend(to: 2, in: [1, 2, 3])
        XCTAssertEqual(selection.ordered([1, 2, 3]), [2])
    }
}

@MainActor
final class BulkActionTests: XCTestCase {
    private let transport = RoutingTransport()

    private func catalogModel() async throws -> CatalogModel {
        let items = [
            Fixtures.item(20, "movie", "Dune"), Fixtures.item(30, "show", "Andor"),
            Fixtures.item(31, "season", "Andor", parent: 30, season: 1),
            Fixtures.item(32, "episode", "Andor", parent: 31, episode: 1),
            Fixtures.item(33, "episode", "Andor", parent: 31, episode: 2),
        ]
        let model = CatalogModel(
            client: ServerEndpoint.default.client(token: "t", transport: transport),
            replica: try replica(items, watch: [Fixtures.watch(32, position: 60_000)], profile: 2), profileId: 2)
        await model.load()
        return model
    }

    func testMarkingASelectionIsOneActionAndMarksAShowsEpisodes() async throws {
        let model = try await catalogModel()
        await model.setWatched(true, for: [model.catalog.item(30)!, model.catalog.item(20)!])
        XCTAssertNil(model.error)
        let queued = try await model.replica.read {
            try String.fetchAll($0, sql: "SELECT operation_id || ' ' || path FROM queue.action")
        }
        XCTAssertEqual(queued, ["putWatchStates /profiles/\(UID.n(2))/watch-state/batch"])
        XCTAssertEqual(model.catalog.unwatchedCount(30), 0)
        XCTAssertTrue(model.catalog.isWatched(20))
        XCTAssertFalse(model.catalog.isInProgress(32))
    }

    func testAMarkOnATitleTheProfileMayNotSeeChangesNothing() async throws {
        let model = try await catalogModel()
        await model.setWatched(
            true, for: [model.catalog.item(20)!, Fixtures.decode(Fixtures.item(99, "movie", "Gone"))])
        XCTAssertNotNil(model.error)
        XCTAssertFalse(model.catalog.isWatched(20))
        let queued = try await model.replica.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM queue.action") }
        XCTAssertEqual(queued, 0)
    }

    func testKidsContentForASelectionIsOneAction() async throws {
        let model = try await catalogModel()
        await model.setKidsContent(true, for: [model.catalog.item(20)!, model.catalog.item(30)!])
        XCTAssertNil(model.error)
        let queued = try await model.replica.read {
            try String.fetchAll($0, sql: "SELECT operation_id || ' ' || path FROM queue.action")
        }
        XCTAssertEqual(queued, ["setKidsContents /items/kids-content/batch"])
        XCTAssertEqual(model.catalog.item(30)?.kidsContent, true)
        XCTAssertEqual(model.catalog.item(30)?.kidsContentOverride, true)
        XCTAssertEqual(model.catalog.item(20)?.kidsContent, true)
    }

    func testAddingASelectionToAPlaylistIsOneAction() async throws {
        let synced = try SyncedReplica { db in
            try db.account(2, "Avery")
            try db.item(100, "movie", "Dune")
            try db.item(101, "movie", "Heat")
            try db.playlist(9, "Mix", owner: 2)
        }
        addTeardownBlock { await synced.remove() }
        let model = synced.playlists(2)
        let added = await model.add([101, 100], to: 9)
        XCTAssertTrue(added)
        XCTAssertEqual(
            try synced.queued(),
            ["addPlaylistEntries POST /profiles/\(UID.n(2))/playlists/\(UID.n(9))/entries/batch"])
        let body = try XCTUnwrap(try synced.lastBody())
        XCTAssertEqual(
            (body["entries"] as? [[String: Any]])?.compactMap { $0["itemId"] as? String },
            ["\(UID.n(101))", "\(UID.n(100))"])
    }

    func testYouTubeSelectionsMarkAndSetForKidsInOneActionEach() async throws {
        let fixture = ReplicaFixture()
        defer { fixture.remove() }
        let replica = try fixture.v1 { db in
            try db.account(1, "Avery")
            try db.channel(60, "Workbench Weekly")
            try db.channel(61, "Lathe Talk")
            try db.video(70, "Dovetails", channel: 60)
            try db.video(71, "Chucks", channel: 61)
        }
        let client = ServerEndpoint.default.client(token: "t", transport: transport)
        let model = YouTubeModel(
            client: client, replica: replica, queue: ActionQueue(replica: replica, client: client), profileId: 1)
        try await model.setWatched(true, items: [60, 61])
        try await model.setForKids(true, channels: [60, 61])
        let queued = try await replica.read {
            try String.fetchAll($0, sql: "SELECT operation_id || ' ' || path FROM queue.action ORDER BY seq")
        }
        XCTAssertEqual(
            queued,
            ["putWatchStates /profiles/\(UID.n(1))/watch-state/batch", "setKidsContents /items/kids-content/batch"])
        let channels = try await model.channels()
        XCTAssertEqual(channels.map(\.forKids), [true, true])
        let video = try await model.video(70).video
        XCTAssertEqual(video.watched, true, "a channel marks its videos")
    }
}
