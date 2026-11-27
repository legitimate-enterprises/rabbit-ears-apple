import Foundation
import GRDB
import HTTPTypes
import RabbitEarsAPI
import XCTest

@testable import RabbitEarsKit

/// What is downloaded, with no server: the replica answers the catalog
/// and the device plays the files, shows their art and switches profiles.
@MainActor
final class OfflineBrowseTests: XCTestCase {
    var harness: DownloadHarness!
    var store: DownloadStore { harness.store }

    override func setUp() async throws {
        harness = DownloadHarness()
        let objects = [
            "GET /music/albums/\(UID.n(50))": Fixtures.album(50, "In Rainbows"),
            "GET /music/artists/\(UID.n(40))": Fixtures.artist,
            "GET /youtube/channels/\(UID.n(60))": Fixtures.channel(60, "Workbench Weekly"),
            "GET /me": Fixtures.me,
        ]
        for (route, json) in objects { harness.objects[route] = json }
        try await harness.replica.write { try $0.downloadedTitles() }
        harness.transport.routes["GET /items/\(UID.n(20))/artwork/poster"] = (.ok, "jpeg")
        harness.transport.headers[.eTag] = "\"a\""
        harness.transport.headers[.cacheControl] = "private, no-cache"
        harness.resolves["item/\(UID.n(10))"] = [
            Fixtures.downloadTitle(101, "episode", position: 60_000), Fixtures.downloadTitle(103, "episode"),
        ]
        harness.resolves["item/\(UID.n(20))"] = [Fixtures.downloadTitle(20, "movie", watched: true)]
        harness.resolves["item/\(UID.n(5))"] = [Fixtures.downloadTitle(5, "song", library: 3)]
        harness.resolves["item/\(UID.n(70))"] = [Fixtures.downloadTitle(70, "video", library: 4)]
        for target in [DownloadTarget.show(10), .title(20), .title(5), .title(70)] {
            try await harness.download(target)
        }
        try harness.keep(me: Fixtures.me)
        try await harness.replica.write { try $0.watch(101, for: 1, position: 60_000) }
    }

    func testOfflineTheCatalogIsTheReplicasDownloadedOrNot() async throws {
        let replica = try replica(
            [
                Fixtures.item(10, "show", "Severance"), Fixtures.item(11, "season", "Season 1", parent: 10, season: 1),
                Fixtures.item(101, "episode", "Good News", parent: 11, season: 1, episode: 1),
                Fixtures.item(103, "episode", "In Perpetuity", parent: 11, season: 1, episode: 3),
                Fixtures.item(20, "movie", "Dune", runtime: 166), Fixtures.item(30, "movie", "Heat"),
            ],
            watch: [Fixtures.watch(101, position: 60_000), Fixtures.watch(20, watched: true)], profile: 1)
        harness.goOffline()
        let model = CatalogModel(client: harness.client, replica: replica, profileId: 1)
        await model.load()
        XCTAssertNil(model.error)
        XCTAssertEqual(Set(model.catalog.items.keys), [10, 11, 101, 103, 20, 30])
        XCTAssertEqual(model.catalog.episodes(under: 10).map(\.id), [101, 103])
        XCTAssertTrue(model.catalog.isWatched(20))
        XCTAssertEqual(model.catalog.continueWatching.map(\.id), [101])
        XCTAssertEqual(store.titles[20]?.state, .onDevice)
        XCTAssertNil(store.titles[30], "Heat shows though it is not on the device")
    }

    /// The replica's Radiohead, In Rainbows with Reckoner, and Workbench Weekly with Dovetails.
    private func musicAndYouTube() throws -> Replica {
        let fixture = ReplicaFixture()
        addTeardownBlock { fixture.remove() }
        return try fixture.v1 { db in
            try db.account(1, "Avery")
            try db.artist(40, "Radiohead")
            try db.album(50, "In Rainbows", artist: 40)
            try db.song(5, "Reckoner", album: 50, track: 7)
            try db.channel(60, "Workbench Weekly")
            try db.video(70, "Dovetails", channel: 60)
        }
    }

    func testMusicYouTubeAndArtworkAnswerFromTheDevice() async throws {
        let replica = try musicAndYouTube()
        harness.goOffline()
        let album = try await MusicModel(client: harness.client, replica: replica, profileId: 1).album(50)
        XCTAssertEqual(album.songs.map(\.title), ["Reckoner"])
        let queue = ActionQueue(replica: replica, client: harness.client)
        let channels = try await YouTubeModel(client: harness.client, replica: replica, queue: queue, profileId: 1)
            .channels()
        XCTAssertEqual(channels.map(\.title), ["Workbench Weekly"])
        let art = ArtworkStore(client: harness.client)
        let poster = await art.data(20, .poster)
        XCTAssertEqual(poster, Data("jpeg".utf8))
        let missing = await art.data(21, .poster)
        XCTAssertNil(missing)
    }

    func testOfflineTheDownloadedAlbumsAndArtistsFileUnderTheirLetters() async throws {
        let replica = try musicAndYouTube()
        harness.goOffline()
        let music = MusicModel(client: harness.client, replica: replica, profileId: 1)
        let albums = try await music.letters(of: .albums)
        XCTAssertEqual(albums.map(\.letter), ["I"], "not an empty library")
        XCTAssertEqual(albums.map(\.count), [1])
        let artists = try await music.letters(of: .artists)
        XCTAssertEqual(artists.map(\.letter), ["R"])
        let underI = try await music.albums(letter: "I")
        XCTAssertEqual(underI.items.map(\.id), [50])
        let underB = try await music.albums(letter: "B")
        XCTAssertEqual(underB.items.map(\.id), [])
        let underR = try await music.artists(letter: "R")
        XCTAssertEqual(underR.items.map(\.id), [40])
        let underT = try await music.artists(letter: "T")
        XCTAssertEqual(underT.items.map(\.id), [])
    }

    func testOfflineADownloadedMovieHasNoRelatedAnswerAndNoError() async {
        harness.goOffline()
        let model = CatalogModel(client: harness.client, profileId: 1)
        await model.load()
        let related = await model.related(20)
        XCTAssertNil(related)
        XCTAssertNil(model.error)
    }

    func testRemovingEveryDownloadRemovesTheirArt() throws {
        let art = harness.directory.appending(path: "art").path(percentEncoded: false)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: art).isEmpty)
        for target in [DownloadTarget.show(10), .title(5), .title(70)] {
            store.remove(target, profile: 1)
        }
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: art), ["item-\(UID.n(20))-poster"],
            "Dune still shows with it")
        store.remove(.title(20), profile: 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: art), [])
    }

    func testOfflineArtUnderAGenerationIsKeptAndACustomImageIsSimplyMissing() async throws {
        let generation = ArtworkGeneration()
        let client = harness.endpoint.client(
            token: "tok-1", transport: harness.transport, generation: generation, offline: store)
        harness.transport.headers[HTTPField.Name("Artwork-Generation")!] = "3"
        _ = try await client.getMe()
        let art = ArtworkStore(client: client, generation: generation)
        harness.goOffline()
        let poster = await art.data(20, .poster)
        XCTAssertEqual(poster, Data("jpeg".utf8))
        let custom = await art.data(imageUrl: "/api/v2/stations/\(UID.n(5))/image?v=\(UID.n(9))")
        XCTAssertNil(custom)
        XCTAssertEqual(generation.value, 3)
        XCTAssertEqual(store.titles[20]?.state, .onDevice)
        let again = await art.data(20, .poster)
        XCTAssertEqual(again, Data("jpeg".utf8))
    }

    func testTheAppOpensOfflineOnItsKeptMeAndSwitchesOnlyToAProfileTheReplicaSaysHasNoPin() async throws {
        harness.goOffline()
        let credentials = MemoryCredentialStore()
        credentials.server = harness.endpoint.baseURL
        credentials.token = "tok-1"
        let app = AppModel(
            store: credentials, deviceName: "Mac", transport: harness.transport, downloads: harness.store,
            replicaDirectory: harness.fixture.directory)
        await app.restore()
        XCTAssertEqual(app.phase, .choosingProfile)
        try await app.choose(try XCTUnwrap(app.profiles.first { $0.id == 1 }))
        XCTAssertEqual(app.phase, .browsing)
        do {
            try await app.choose(try XCTUnwrap(app.profiles.first { $0.id == 2 }), pin: "1234")
            XCTFail("a PIN can't be checked offline")
        } catch {}
        try await harness.replica.write { try $0.execute(sql: "UPDATE account SET has_pin = 1 WHERE id = \(sqlID(1))") }
        do {
            try await app.unlock(try XCTUnwrap(app.profiles.first { $0.id == 1 }))
            XCTFail("a PIN set since the Me was kept is the server's to check")
        } catch {
            XCTAssertEqual(error as? AppError, .unreachable)
        }
    }

    func testOfflineTheDownloadsAnswerNoCatalogWatchStateOrUpNext() async {
        harness.goOffline()
        let calls: [(String, () async throws -> Void)] = [
            ("listItems", { _ = try await self.harness.client.listItems(query: .init(kind: .movie)).ok }),
            ("getItem", { _ = try await self.harness.client.getItem(path: .init(itemId: 20)).ok }),
            ("listWatchStates", { _ = try await self.harness.client.listWatchStates(path: .init(profileId: 1)).ok }),
            ("getUpNext", { _ = try await self.harness.client.getUpNext(path: .init(profileId: 1, itemId: 101)).ok }),
            ("listMusicSongs", { _ = try await self.harness.client.listMusicSongs().ok }),
            ("listPlaylists", { _ = try await self.harness.client.listPlaylists(path: .init(profileId: 1)).ok }),
        ]
        for (name, call) in calls {
            do {
                try await call()
                XCTFail("\(name) answered from the downloads")
            } catch {
                XCTAssertTrue(OfflineMiddleware.unreachable(error), name)
            }
        }
    }

    /// Visibility is the replica's per profile: a kid sees what its ceiling lets it, and none of another's progress.
    func testAnotherProfileSeesTheReplicaAsItsVisibilityLetsIt() async throws {
        try await harness.replica.write { db in
            try db.account(2, "Robin", kind: "kid", movies: "PG")
            try db.execute(sql: "UPDATE item_metadata SET content_rating = 'PG-13' WHERE item_id = \(sqlID(20))")
            try db.item(41, "movie", "Paddington", rating: "PG")
            try db.watch(41, for: 1, position: 90_000)
        }
        harness.goOffline()
        let model = CatalogModel(client: harness.client, replica: harness.replica, profileId: 2)
        await model.load()
        XCTAssertEqual(Set(model.catalog.items.keys), [41], "Dune is above the kid's ceiling, downloaded or not")
        XCTAssertNil(model.catalog.watch[41], "Avery's progress is Avery's")
    }

    func testWithNothingDownloadedTheServerIsUnreachableAsBefore() async {
        harness.store.wipe()
        harness.goOffline()
        let credentials = MemoryCredentialStore()
        credentials.server = harness.endpoint.baseURL
        credentials.token = "tok-1"
        let app = AppModel(
            store: credentials, deviceName: "Mac", transport: harness.transport, downloads: harness.store,
            replicaDirectory: Fixtures.replicas)
        await app.restore()
        XCTAssertEqual(app.phase, .unreachable)
    }

    func testWithNothingDownloadedTheLibraryIsUnreachableRatherThanEmpty() async {
        harness.store.wipe()
        harness.goOffline()
        do {
            _ = try await harness.client.listItems(query: .init(kind: .movie)).ok
            XCTFail("listItems answered with nothing downloaded")
        } catch {
            XCTAssertTrue(OfflineMiddleware.unreachable(error))
        }
        do {
            _ = try await harness.client.listPlaylists(path: .init(profileId: 1)).ok
            XCTFail("listPlaylists answered with nothing downloaded")
        } catch {
            XCTAssertTrue(OfflineMiddleware.unreachable(error))
        }
    }

    func testWithNothingDownloadedTheCatalogReadsTheSameWhenTheServerGoes() async throws {
        harness.store.wipe()
        let model = CatalogModel(
            client: harness.client, replica: try replica([Fixtures.item(20, "movie", "Dune")], profile: 1),
            profileId: 1)
        await model.load()
        XCTAssertNotNil(model.catalog.item(20))

        harness.goOffline()
        await model.load()
        XCTAssertNotNil(model.catalog.item(20))
        XCTAssertNil(model.error, "the replica answers; nothing is wrong")
    }

    func testThePlayerPlaysTheFileFromWhereTheReplicaSaysTheProfileLeftIt() async throws {
        harness.goOffline()
        let output = FakeOutput()
        let item = Fixtures.decode(Fixtures.item(101, "episode", "Good News", parent: 11), as: Item.self)
        let player = PlayerModel(
            client: harness.client, endpoint: harness.endpoint, profileId: 1, item: item, output: output,
            capabilities: FakeCapabilities(), fetchText: { _ in "" })
        await player.start()
        let loaded = try XCTUnwrap(output.loaded.last)
        XCTAssertTrue(loaded.0.isFileURL)
        XCTAssertEqual(loaded.0, store.titles[101].flatMap(store.file(of:)))
        XCTAssertEqual(loaded.1, 60, "resumes where the profile left it")
        XCTAssertEqual(player.stream?.sidecars.first.map { URL(string: $0.url)?.isFileURL }, true)
    }

    /// A kept file carries every text track, unlike a stream's one sidecar.
    func testAKeptFileDrawsOnlyAForcedTrackUntilAnotherIsPicked() async throws {
        store.ledger.titles[20]?.subtitles = [
            StoredSubtitle(trackId: 5, language: "eng", title: "SDH", isForced: false, file: "20-5.vtt")
        ]
        harness.goOffline()
        let item = Fixtures.decode(Fixtures.item(20, "movie", "Dune"), as: Item.self)
        let player = PlayerModel(
            client: harness.client, endpoint: harness.endpoint, profileId: 1, item: item, output: FakeOutput(),
            capabilities: FakeCapabilities(),
            fetchText: { url in "WEBVTT\n\n00:00:01.000 --> 00:00:09.000\n\(url.lastPathComponent)\n" })
        await player.start(positionMs: 0)
        XCTAssertNil(player.cue(at: 2), "forced only draws no full track")
        await player.selectSubtitles(.track(5))
        XCTAssertEqual(player.cue(at: 2), "20-5.vtt")
    }

    func testAPreferredLocalCopyPlaysWithoutTheServerAndOffItStreams() async throws {
        let item = Fixtures.decode(Fixtures.item(20, "movie", "Dune"), as: Item.self)
        harness.transport.routes["POST /playback/sessions"] = (.created, Fixtures.stream())
        let local = FakeOutput()
        await PlayerModel(
            client: harness.client, endpoint: harness.endpoint, profileId: 1, item: item, output: local,
            capabilities: FakeCapabilities(), fetchText: { _ in "" }
        ).start()
        XCTAssertEqual(local.loaded.last?.0.isFileURL, true)
        XCTAssertFalse(harness.transport.paths(.post).contains("/playback/sessions"))

        var settings = store.settings(1)
        settings.preferLocal = false
        store.setSettings(settings, for: 1)
        let streamed = FakeOutput()
        await PlayerModel(
            client: harness.client, endpoint: harness.endpoint, profileId: 1, item: item, output: streamed,
            capabilities: FakeCapabilities(), fetchText: { _ in "" }
        ).start()
        XCTAssertEqual(streamed.loaded.last?.0.isFileURL, false)
    }

    func testAPreferredLocalCopyOfAnotherEditionStreamsUnlessTheServerIsGone() async throws {
        let item = Fixtures.decode(Fixtures.item(20, "movie", "Dune"), as: Item.self)
        harness.transport.routes["POST /playback/sessions"] = (.created, Fixtures.stream())
        store.ledger.titles[20]?.editionId = 7
        func play(edition: UID) async -> URL? {
            let output = FakeOutput()
            await PlayerModel(
                client: harness.client, endpoint: harness.endpoint, profileId: 1, item: item, output: output,
                capabilities: FakeCapabilities(), fetchText: { _ in "" }
            ).start(editionId: edition)
            return output.loaded.last?.0
        }
        let other = await play(edition: 8)
        XCTAssertEqual(other?.isFileURL, false, "the edition asked for streams")
        let same = await play(edition: 7)
        XCTAssertEqual(same?.isFileURL, true)

        harness.goOffline()
        let offline = await play(edition: 8)
        XCTAssertEqual(offline?.isFileURL, true, "offline, the copy there plays")
    }
}

extension Database {
    /// What the downloads' art is read from.
    fileprivate func downloadedTitles() throws {
        try item(10, "show", "Severance")
        try item(11, "season", "Season 1", parent: 10, season: 1)
        try item(101, "episode", "Good News", parent: 11, season: 1, episode: 1)
        try item(103, "episode", "In Perpetuity", parent: 11, season: 1, episode: 3)
        try item(20, "movie", "Dune", runtime: 166)
        try artist(40, "Radiohead")
        try album(50, "In Rainbows", artist: 40)
        try song(5, "Reckoner", album: 50, track: 7)
        try channel(60, "Workbench Weekly")
        try video(70, "Dovetails", channel: 60)
    }
}
