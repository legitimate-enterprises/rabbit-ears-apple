import Foundation
import GRDB
import RabbitEarsAPI
import XCTest

@testable import RabbitEarsKit

/// A play of a downloaded file saves where it got to and counts its finish
/// as queued actions, each with when it happened, online or not.
@MainActor
final class WatchSyncTests: XCTestCase {
    var harness: DownloadHarness!
    var store: DownloadStore { harness.store }
    var calls: [PlayLog.Call] { harness.plays.calls }

    override func setUp() async throws {
        harness = DownloadHarness()
        harness.objects["GET /items/20"] = Fixtures.item(20, "movie", "Dune", runtime: 100)
        harness.objects["GET /items/21"] = Fixtures.item(21, "movie", "Arrival", runtime: 100)
        harness.resolves["item/20"] = [Fixtures.downloadTitle(20, "movie", runtime: 6_000_000)]
        harness.resolves["item/21"] = [Fixtures.downloadTitle(21, "movie", runtime: 6_000_000)]
        try await harness.download(.title(20))
        try await harness.download(.title(21))
        try await harness.replica.write { db in
            try db.item(20, "movie", "Dune", runtime: 100)
            try db.item(21, "movie", "Arrival", runtime: 100)
        }
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

    /// The session a local start answers, for sending its reports by hand.
    private func start(_ id: Int64) async throws -> Int64 {
        let snapshot = await harness.endpoint.snapshot(harness.box.facts, checkedWith: harness.client, maxBitrate: nil)
        let stream = try await harness.client.startPlayback(
            body: .json(.init(profileId: 1, itemId: id, snapshot: snapshot))
        ).created.body.json
        XCTAssertLessThan(stream.sessionId, 0, "played from the device")
        return stream.sessionId
    }

    private func report(_ session: Int64, at positionMs: Int64) async throws {
        _ = try await harness.client.reportPlaybackPosition(
            path: .init(sessionId: session), body: .json(.init(positionMs: positionMs, paused: false))
        ).noContent
    }

    func testOfflinePlaySavesItsPositionAndAFinishIsOnePlayEachWithItsInstant() async throws {
        harness.plays.replica = harness.replica
        harness.goOffline()
        let first = harness.box.now
        await play(21, to: 1_200_000)
        harness.box.now = first.addingTimeInterval(60)
        await play(20, to: 5_700_000)

        XCTAssertEqual(
            calls.last { if case .progress(_, 21, _, _, _, _) = $0 { true } else { false } },
            .progress(profile: 1, item: 21, edition: nil, positionMs: 1_200_000, watched: false, at: first))
        XCTAssertEqual(
            calls.filter { if case .finished = $0 { true } else { false } },
            [.finished(profile: 1, item: 20, edition: nil, at: first.addingTimeInterval(60))],
            "90% played is one play")
        XCTAssertFalse(
            calls.contains(
                .progress(
                    profile: 1, item: 20, edition: nil, positionMs: 0, watched: true, at: first.addingTimeInterval(60)))
        )
        XCTAssertFalse(
            harness.transport.sent.contains { $0.path.contains("watch-state") || $0.path.contains("/plays") })

        let model = CatalogModel(client: harness.client, replica: harness.replica, profileId: 1)
        await model.load()
        XCTAssertTrue(model.catalog.isWatched(20), "the catalog reads the play from the replica")
        XCTAssertEqual(model.catalog.watch[21]?.positionMs, 1_200_000)
    }

    func testAFinishedPlaySendsNothingMoreAndNeverAWatchedProgress() async throws {
        let session = try await start(20)
        try await report(session, at: 3_000_000)
        try await report(session, at: 3_000_000)
        try await report(session, at: 5_500_000)
        try await report(session, at: 5_800_000)
        _ = try await harness.client.endPlayback(path: .init(sessionId: session), query: .init(positionMs: 5_900_000))
            .noContent
        let at = harness.box.now
        XCTAssertEqual(
            calls,
            [
                .progress(profile: 1, item: 20, edition: nil, positionMs: 3_000_000, watched: false, at: at),
                .finished(profile: 1, item: 20, edition: nil, at: at),
            ], "a position already saved is not saved again")
    }

    func testAnUnfinishedPlayOfAWatchedTitleKeepsItWatched() async throws {
        try await harness.replica.write { try $0.watch(21, for: 1, watched: true) }
        let session = try await start(21)
        try await report(session, at: 1_200_000)
        XCTAssertEqual(
            calls,
            [.progress(profile: 1, item: 21, edition: nil, positionMs: 1_200_000, watched: true, at: harness.box.now)])
    }

    func testSignedInALocalPlayGoesToTheSessionsQueueAndAFinishIsOnlyOnePlay() async throws {
        try harness.keep(me: Fixtures.me)
        harness.goOffline()
        let credentials = MemoryCredentialStore()
        credentials.server = harness.endpoint.baseURL
        credentials.token = "tok-1"
        let app = AppModel(
            store: credentials, deviceName: "Mac", transport: harness.transport, downloads: store,
            replicaDirectory: harness.fixture.directory)
        await app.restore()
        let sync = try XCTUnwrap(app.sync)
        let session = try await start(20)
        try await report(session, at: 3_000_000)
        try await report(session, at: 5_500_000)
        try await report(session, at: 5_800_000)

        let queued = try await sync.replica.read { db in
            try Row.fetchAll(db, sql: "SELECT operation_id, body FROM queue.action ORDER BY seq").map {
                let body = try JSONSerialization.jsonObject(with: $0["body"] as Data) as? [String: Any]
                return "\($0["operation_id"] as String) \(body?["watched"] as? Bool ?? false)"
            }
        }
        XCTAssertEqual(queued, ["putWatchState false", "recordPlay false"])
        XCTAssertTrue(calls.isEmpty, "the session's queue takes them")
    }

    func testOnlineALocalPlayGoesThroughTheQueueToo() async throws {
        await play(21, to: 1_200_000)
        XCTAssertTrue(
            calls.contains(
                .progress(
                    profile: 1, item: 21, edition: nil, positionMs: 1_200_000, watched: false, at: harness.box.now)))
        XCTAssertFalse(harness.transport.paths(.post).contains("/playback/sessions"))
        XCTAssertFalse(harness.transport.sent.contains { $0.path.contains("watch-state") })
    }

    func testAFinishedLocalPlayTakesAWatchedEpisodeOutOfAStandingRequest() async throws {
        harness.plays.replica = harness.replica
        harness.resolves["item/10"] = [
            Fixtures.downloadTitle(101, "episode", library: 2, runtime: 6_000_000),
            Fixtures.downloadTitle(102, "episode", library: 2, runtime: 6_000_000),
        ]
        try await harness.download(.show(10))
        let session = try await start(101)
        try await report(session, at: 5_500_000)
        XCTAssertEqual(store.request(.show(10), profile: 1)?.titles, [102], "TV removes a title once watched")
        XCTAssertNil(store.titles[101])
    }
}
