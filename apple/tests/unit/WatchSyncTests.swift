import Foundation
import RabbitEarsAPI
import XCTest

@testable import RabbitEarsKit

/// Progress made offline reaches the server with when it happened, oldest first.
@MainActor
final class WatchSyncTests: XCTestCase {
    var harness: DownloadHarness!
    var store: DownloadStore { harness.store }

    override func setUp() async throws {
        harness = DownloadHarness()
        harness.objects["GET /items/20"] = Fixtures.item(20, "movie", "Dune", runtime: 100)
        harness.objects["GET /items/21"] = Fixtures.item(21, "movie", "Arrival", runtime: 100)
        harness.objects["GET /me"] = Fixtures.me
        harness.resolves["item/20"] = [Fixtures.downloadTitle(20, "movie", runtime: 6_000_000)]
        harness.resolves["item/21"] = [Fixtures.downloadTitle(21, "movie", runtime: 6_000_000)]
        try await harness.download(.title(20))
        try await harness.download(.title(21))
        _ = try await harness.client.getMe()
    }

    private func play(_ id: Int64, to positionMs: Int64) async {
        let output = FakeOutput()
        let item = Fixtures.decode(Fixtures.item(id, "movie", "Movie"), as: Item.self)
        let player = PlayerModel(
            client: harness.client, endpoint: harness.endpoint, profileId: 1, item: item, output: output,
            capabilities: FakeCapabilities(), fetchText: { _ in "" })
        await player.start()
        output.positionMs = positionMs
        await player.stop()
    }

    func testOfflinePlayKeepsEachChangeWithItsInstant() async {
        harness.goOffline()
        let first = harness.box.now
        await play(21, to: 1_200_000)
        harness.box.now = first.addingTimeInterval(60)
        await play(20, to: 5_700_000)

        let changes = store.unsynced(1)
        XCTAssertEqual(changes[21], LocalWatch(watched: false, positionMs: 1_200_000, at: first))
        XCTAssertEqual(
            changes[20], LocalWatch(watched: true, positionMs: 0, at: first.addingTimeInterval(60)),
            "90% played is watched, which clears the position")
        let model = CatalogModel(client: harness.client, profileId: 1)
        await model.load()
        XCTAssertTrue(model.catalog.isWatched(20))
        XCTAssertEqual(model.catalog.watch[21]?.positionMs, 1_200_000)
    }

    func testBackOnlineTheChangesGoOldestFirstWithWhenTheyHappened() async throws {
        harness.goOffline()
        let first = harness.box.now
        await play(20, to: 5_700_000)
        harness.box.now = first.addingTimeInterval(60)
        await play(21, to: 1_200_000)
        let newer =
            #"{"itemId":21,"positionMs":3000,"watched":false,"playCount":0,"updatedAt":"2027-01-01T00:00:00Z"}"#
        harness.transport.routes["PUT /profiles/1/watch-state/21"] = (.ok, newer)
        harness.transport.routes["PUT /profiles/1/watch-state/20"] = (.ok, Fixtures.watch(20, watched: true))

        harness.goOnline()
        await store.sync(profile: 1)
        let puts = harness.transport.sent.filter { $0.method == .put }
        XCTAssertEqual(puts.map(\.path), ["/profiles/1/watch-state/20", "/profiles/1/watch-state/21"])
        let sent = Fixtures.decode(puts[0].body, as: Components.Schemas.WatchStateInput.self)
        XCTAssertEqual(sent.at, first)
        XCTAssertEqual(sent.watched, true)
        XCTAssertTrue(store.unsynced(1).isEmpty)
        XCTAssertEqual(
            store.ledger.shelf.watch[1]?[21]?.positionMs, 3000, "a newer change on the server wins and is kept here")
    }

    func testAChangeTheServerFailsToSaveIsKeptAndSentNextTime() async throws {
        harness.goOffline()
        let at = harness.box.now
        await play(20, to: 1_200_000)
        harness.transport.routes["PUT /profiles/1/watch-state/20"] = (.internalServerError, Fixtures.error("internal"))

        harness.goOnline()
        await store.sync(profile: 1)
        XCTAssertEqual(store.unsynced(1)[20], LocalWatch(watched: false, positionMs: 1_200_000, at: at))

        harness.transport.routes["PUT /profiles/1/watch-state/20"] = (.ok, Fixtures.watch(20, watched: false))
        await store.sync(profile: 1)
        XCTAssertTrue(store.unsynced(1).isEmpty)
        let puts = harness.transport.sent.filter { $0.method == .put }
        XCTAssertEqual(puts.count, 2)
        let resent = Fixtures.decode(try XCTUnwrap(puts.last).body, as: Components.Schemas.WatchStateInput.self)
        XCTAssertEqual(resent.at, at)
    }

    func testAChangeForATitleTheServerNoLongerHasIsDropped() async {
        harness.goOffline()
        await play(20, to: 1_200_000)
        harness.transport.routes["PUT /profiles/1/watch-state/20"] = (.notFound, Fixtures.error("not_found"))

        harness.goOnline()
        await store.sync(profile: 1)
        XCTAssertTrue(store.unsynced(1).isEmpty)
    }

    func testAForgottenDeviceSendingItsChangesLosesItsDownloads() async {
        harness.goOffline()
        await play(20, to: 1_200_000)
        harness.transport.routes["PUT /profiles/1/watch-state/20"] = (.unauthorized, Fixtures.error("unauthorized"))

        harness.goOnline()
        await store.sync(profile: 1)
        XCTAssertFalse(store.hasDownloads)
        XCTAssertTrue(store.unsynced(1).isEmpty)
    }

    func testAChangeMetByA401TheServerDidNotSendIsKeptWithEveryDownload() async {
        harness.goOffline()
        await play(20, to: 1_200_000)
        harness.transport.routes["PUT /profiles/1/watch-state/20"] = (.unauthorized, "<html>401</html>")

        harness.goOnline()
        await store.sync(profile: 1)
        XCTAssertTrue(store.hasDownloads)
        XCTAssertEqual(store.unsynced(1).keys.sorted(), [20])
    }

    func testAChangeMetByA404TheServerDidNotSendIsKept() async {
        harness.goOffline()
        await play(20, to: 1_200_000)
        harness.transport.routes["PUT /profiles/1/watch-state/20"] = (.notFound, "<html>404 Not Found</html>")

        harness.goOnline()
        await store.sync(profile: 1)
        XCTAssertEqual(store.unsynced(1).keys.sorted(), [20])
    }

    func testAChangeOnlineStillGoesStraightToTheServer() async {
        harness.transport.routes["PUT /profiles/1/watch-state/20"] = (.ok, Fixtures.watch(20, watched: true))
        let model = CatalogModel(client: harness.client, profileId: 1)
        let item = Fixtures.decode(Fixtures.item(20, "movie", "Dune"), as: Item.self)
        await model.setWatched(true, for: item)
        XCTAssertTrue(store.unsynced(1).isEmpty)
        XCTAssertEqual(harness.transport.paths(.put), ["/profiles/1/watch-state/20"])
    }

    func testMarkingWatchedOfflineIsKeptToSendLater() async throws {
        harness.goOffline()
        let model = CatalogModel(client: harness.client, profileId: 1)
        await model.load()
        let item = try XCTUnwrap(model.catalog.item(21))
        await model.setWatched(true, for: [item])
        XCTAssertNil(model.error)
        XCTAssertEqual(store.unsynced(1)[21]?.watched, true)
    }
}
