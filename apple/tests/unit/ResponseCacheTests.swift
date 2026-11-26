import Foundation
import HTTPTypes
import RabbitEarsAPI
import XCTest

@testable import RabbitEarsKit

/// The server's answers kept on the device, read through by every model.
@MainActor
final class ResponseCacheTests: XCTestCase {
    let directory = FileManager.default.temporaryDirectory.appending(path: "Responses \(UUID().uuidString)")
    var transport: RoutingTransport!
    var cache: ResponseCache!
    var client: Client!
    /// What a view reading again on each signal got.
    var reads: [[Int64]] = []

    override func setUp() async throws {
        transport = RoutingTransport([
            "GET /me": (.ok, Fixtures.me),
            "GET /items": (.ok, Fixtures.page([Fixtures.item(20, "movie", "Dune")])),
            "GET /profiles/1/watch-state": (.ok, Fixtures.page([Fixtures.watch(20, position: 60_000)])),
            "PUT /profiles/1/watch-state/20": (.ok, Fixtures.watch(20, watched: true)),
        ])
        cache = makeCache()
        client = ServerEndpoint.default.client(token: "t", transport: transport, cache: cache)
        _ = try await client.getMe()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func makeCache() -> ResponseCache { ResponseCache(directory: directory) }

    func movies(_ client: Client? = nil) async throws -> [Int64] {
        try await (client ?? self.client).listItems(query: .init(kind: .movie)).ok.body.json.items.map(\.id)
    }

    func asked(_ path: String, in transport: RoutingTransport? = nil) -> Int {
        (transport ?? self.transport).paths(.get).filter { $0 == path }.count
    }

    func listsNext(_ id: Int64) {
        transport.routes["GET /items"] = (.ok, Fixtures.page([Fixtures.item(id, "movie", "M")]))
    }

    /// Reads that do not wait on the server end well within this.
    func atOnce<T>(_ read: () async throws -> T) async throws -> T {
        let started = ContinuousClock.now
        let value = try await read()
        XCTAssertLessThan(started.duration(to: .now), .seconds(1), "answered without waiting on the server")
        return value
    }

    func markWatched() async throws {
        _ = try await client.putWatchState(
            path: .init(profileId: 1, itemId: 20), body: .json(.init(watched: true))
        ).ok
    }

    func testAReloadWithTheServerGoneKeepsTheWholeLibraryUntilTheServerAnswersAgain() async throws {
        let harness = DownloadHarness()
        harness.objects["GET /me"] = Fixtures.me
        harness.objects["GET /music/songs/5"] = Fixtures.song(5, "Reckoner", album: 50, track: 7)
        harness.objects["GET /music/albums/50"] = Fixtures.album(50, "In Rainbows")
        harness.objects["GET /music/artists/40"] = Fixtures.artist
        harness.resolves["item/5"] = [Fixtures.downloadTitle(5, "song", library: 3)]
        try await harness.download(.title(5))
        harness.objects["GET /items"] = Fixtures.page([Fixtures.item(20, "movie", "Dune")])
        harness.objects["GET /profiles/1/watch-state"] = Fixtures.page([])
        let client = harness.endpoint.client(
            token: "tok-1", transport: harness.transport, offline: harness.store, cache: cache)
        _ = try await client.getMe()
        let live = LiveFeed(cache: cache)
        let model = CatalogModel(client: client, profileId: 1)
        await model.load()
        XCTAssertNotNil(model.catalog.item(20))

        harness.goOffline()
        live.tell([])
        await model.heard([])
        XCTAssertNotNil(model.catalog.item(20), "the library the server last answered, not only the song downloaded")

        harness.goOnline()
        harness.objects["GET /items"] = Fixtures.page([Fixtures.item(21, "movie", "Heat")])
        // As on each of the cache's signals, until the server's answer is in.
        for _ in 0..<400 where model.catalog.item(21) == nil {
            await model.heard([])
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertNil(model.catalog.item(20))
        XCTAssertNotNil(model.catalog.item(21))
    }

    func testOfflineWatchChangesShowOverTheStatesTheServerLastAnswered() async throws {
        let harness = DownloadHarness()
        harness.objects["GET /me"] = Fixtures.me
        harness.objects["GET /items/20"] = Fixtures.item(20, "movie", "Dune")
        harness.resolves["item/20"] = [Fixtures.downloadTitle(20, "movie")]
        try await harness.download(.title(20))
        harness.objects["GET /items"] = Fixtures.page([
            Fixtures.item(20, "movie", "Dune"), Fixtures.item(21, "movie", "Heat"),
        ])
        harness.objects["GET /profiles/1/watch-state"] = Fixtures.page([Fixtures.watch(21, position: 5_000)])
        let client = harness.endpoint.client(
            token: "tok-1", transport: harness.transport, offline: harness.store, cache: cache)
        _ = try await client.getMe()
        let live = LiveFeed(cache: cache)
        let model = CatalogModel(client: client, profileId: 1)
        await model.load()

        harness.goOffline()
        await model.setWatched(true, for: try XCTUnwrap(model.catalog.item(20)))
        live.tell([])
        await model.heard([])
        XCTAssertTrue(model.catalog.isWatched(20), "this device's change, not yet on the server")
        XCTAssertTrue(model.catalog.isInProgress(21), "the server's last answer for what is not downloaded")
        XCTAssertNotNil(model.catalog.item(21))
    }

    func testAProfileIsOnlyEverAnsweredWithItsOwnKeptAnswers() async throws {
        let server = ActiveProfile()
        transport.respond = { sent in
            switch (sent.method, sent.path) {
            case (.post, "/me/lock"): return (.noContent, "")
            case (.post, "/profiles/2/unlock"):
                server.id = 2
                return (.noContent, "")
            case (.get, "/items"):
                let title = server.id == 1 ? Fixtures.item(20, "movie", "Dune") : Fixtures.item(30, "movie", "Bluey")
                return (.ok, Fixtures.page([title]))
            default: return nil
            }
        }
        let adult = try await movies()
        XCTAssertEqual(adult, [20])

        _ = try await client.lockDevice().noContent
        _ = try await client.unlockProfile(path: .init(profileId: 2), body: .json(.init(pin: "1234"))).noContent
        transport.failure = URLError(.notConnectedToInternet)
        do {
            let leaked = try await movies()
            XCTFail("the kid was answered with the adult's \(leaked)")
        } catch {
            XCTAssertTrue(OfflineMiddleware.unreachable(error))
        }

        transport.failure = nil
        let kid = try await movies()
        XCTAssertEqual(kid, [30])
        transport.failure = URLError(.notConnectedToInternet)
        let offline = try await movies()
        XCTAssertEqual(offline, [30], "the kid's own last answer")

        let relaunched = ServerEndpoint.default.client(token: "t", transport: transport, cache: makeCache())
        do {
            _ = try await movies(relaunched)
            XCTFail("no profile is known to be active until the server or the downloads say which")
        } catch {
            XCTAssertTrue(OfflineMiddleware.unreachable(error))
        }
    }

    func testOnlyTheServersSuccessfulReadsAreKept() async throws {
        transport.routes["GET /items"] = (.internalServerError, Fixtures.error("internal"))
        _ = try? await movies()
        transport.routes["GET /items"] = (.ok, Fixtures.page([Fixtures.item(20, "movie", "Dune")]))
        _ = try await movies()
        XCTAssertEqual(asked("/items"), 2, "an error is not kept")

        transport.routes["GET /events"] = (.ok, Fixtures.events("c1"))
        transport.routes["GET /profiles/1/watch-state/20"] = (.ok, Fixtures.watch(20))
        transport.routes["GET /profiles/1/downloads/3"] = (.ok, Fixtures.download(3, item: 20))
        transport.routes["GET /playback/sessions/7"] = (.ok, Fixtures.playing(7))
        transport.routes["GET /stations"] = (.ok, Fixtures.page([]))
        for _ in 0..<2 {
            _ = try await client.listEvents(query: .init()).ok
            _ = try await client.getWatchState(path: .init(profileId: 1, itemId: 20)).ok
            _ = try await client.getDownload(path: .init(profileId: 1, downloadId: 3)).ok
            _ = try await client.getPlaybackSession(path: .init(sessionId: 7)).ok
            _ = try await client.listStations(query: .init()).ok
        }
        for path in ["/events", "/profiles/1/watch-state/20", "/profiles/1/downloads/3", "/playback/sessions/7"] {
            XCTAssertEqual(asked(path), 2, "\(path) is asked each time")
        }
        XCTAssertEqual(asked("/stations"), 2, "what is on air changes with the time")
    }

    func testAKeptPlaylistAnswerWithoutItsSharedFlagReadsUnbadged() async throws {
        transport.routes["GET /profiles/1/playlists"] = (
            .ok, Fixtures.page([Fixtures.playlist(3, "Mix"), Fixtures.playlist(4, "Ours", shared: true)])
        )
        await PlaylistsModel(client: client, profileId: 1).load()
        transport.failure = URLError(.notConnectedToInternet)
        let model = PlaylistsModel(client: client, profileId: 1)
        await model.load()
        XCTAssertNil(model.error)
        XCTAssertEqual(model.playlists.map(\.isShared), [false, true])
    }

    func testAWatchStateReadAfterPlayComesFromTheServer() async throws {
        transport.routes["GET /profiles/1/watch-state/20"] = (.ok, Fixtures.watch(20, position: 60_000))
        let model = CatalogModel(client: client, profileId: 1)
        await model.refreshWatchState(20)
        XCTAssertTrue(model.catalog.isInProgress(20))
        transport.routes["GET /profiles/1/watch-state/20"] = (.ok, Fixtures.watch(20, watched: true))
        await model.refreshWatchState(20)
        XCTAssertTrue(model.catalog.isWatched(20))
    }
}

/// The profile a fake server answers as, changed by an unlock.
final class ActiveProfile: @unchecked Sendable {
    var id: Int64 = 1
}
