import Foundation
import HTTPTypes
import RabbitEarsAPI
import XCTest

@testable import RabbitEarsKit

/// The models, run against what is downloaded with no server.
@MainActor
final class OfflineBrowseTests: XCTestCase {
    var harness: DownloadHarness!
    var store: DownloadStore { harness.store }

    override func setUp() async throws {
        harness = DownloadHarness()
        let objects = [
            "GET /items/10": Fixtures.item(10, "show", "Severance"),
            "GET /items/11": Fixtures.item(11, "season", "Season 1", parent: 10, season: 1),
            "GET /items/101": Fixtures.item(101, "episode", "Good News", parent: 11, season: 1, episode: 1),
            "GET /items/103": Fixtures.item(103, "episode", "In Perpetuity", parent: 11, season: 1, episode: 3),
            "GET /items/20": Fixtures.item(20, "movie", "Dune", runtime: 166),
            "GET /music/songs/5": Fixtures.song(5, "Reckoner", album: 50, track: 7),
            "GET /music/albums/50": Fixtures.album(50, "In Rainbows"),
            "GET /music/artists/40": Fixtures.artist,
            "GET /youtube/videos/70": Fixtures.video(70, "Dovetails"),
            "GET /youtube/channels/60": Fixtures.channel(60, "Workbench Weekly"),
            "GET /me": Fixtures.me,
        ]
        for (route, json) in objects { harness.objects[route] = json }
        harness.transport.routes["GET /items/20/artwork/poster"] = (.ok, "jpeg")
        harness.transport.headers[.eTag] = "\"a\""
        harness.transport.headers[.cacheControl] = "private, no-cache"
        harness.resolves["item/10"] = [
            Fixtures.downloadTitle(101, "episode", position: 60_000), Fixtures.downloadTitle(103, "episode"),
        ]
        harness.resolves["item/20"] = [Fixtures.downloadTitle(20, "movie", watched: true)]
        harness.resolves["item/5"] = [Fixtures.downloadTitle(5, "song", library: 3)]
        harness.resolves["item/70"] = [Fixtures.downloadTitle(70, "video", library: 4)]
        for target in [DownloadTarget.show(10), .title(20), .title(5), .title(70)] {
            try await harness.download(target)
        }
        _ = try await harness.client.getMe()
    }

    func testTheCatalogHoldsOnlyWhatIsDownloadedWithItsProgress() async {
        harness.goOffline()
        let model = CatalogModel(client: harness.client, profileId: 1)
        await model.load()
        XCTAssertNil(model.error)
        XCTAssertEqual(Set(model.catalog.items.keys), [10, 11, 101, 103, 20])
        XCTAssertEqual(model.catalog.episodes(under: 10).map(\.id), [101, 103])
        XCTAssertTrue(model.catalog.isWatched(20))
        XCTAssertEqual(model.catalog.continueWatching.map(\.id), [101])
        XCTAssertEqual(store.titles[20]?.state, .onDevice)
    }

    func testOfflineNothingIsInSeasonSoHomeDropsItsSeasonalShelves() async throws {
        harness.goOffline()
        let answer = try await harness.client.listActiveOccasions(
            path: .init(profileId: 1), query: .init(date: "2026-12-01")
        )
        .ok.body.json
        XCTAssertTrue(answer.items.isEmpty)
    }

    func testAPlaylistStoredWithoutItsSharedFlagReadsUnbadged() async throws {
        harness.objects["GET /profiles/1/playlists/3"] = Fixtures.playlist(3, "Mix")
        harness.resolves["playlist/3"] = [Fixtures.downloadTitle(5, "song", library: 3)]
        try await harness.download(.playlist(3))
        // The playlist's own description is kept in a task of its own after the request.
        for _ in 0..<400 where store.ledger.shelf.playlists[3] == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        let ledger = try String(contentsOf: store.ledgerFile, encoding: .utf8)
        XCTAssertTrue(ledger.contains(#""Mix""#))
        XCTAssertFalse(ledger.contains(#""shared""#))
        let reopened = DownloadStore(
            directory: harness.directory, downloader: FakeDownloader(), facts: { fatalError() })
        XCTAssertEqual(reopened.ledger.shelf.playlists[3]?.playlist.isShared, false)

        harness.goOffline()
        let model = PlaylistsModel(client: harness.client, profileId: 1)
        await model.load()
        XCTAssertEqual(model.playlists.map(\.name), ["Mix"])
        XCTAssertEqual(model.playlists.map(\.isShared), [false])
    }

    func testMusicYouTubeAndArtworkAnswerFromTheDevice() async throws {
        harness.goOffline()
        let album = try await MusicModel(client: harness.client, profileId: 1).album(50)
        XCTAssertEqual(album.songs.map(\.title), ["Reckoner"])
        let channels = try await YouTubeModel(client: harness.client, profileId: 1).channels()
        XCTAssertEqual(channels.map(\.title), ["Workbench Weekly"])
        let art = ArtworkStore(client: harness.client)
        let poster = await art.data(20, .poster)
        XCTAssertEqual(poster, Data("jpeg".utf8))
        let missing = await art.data(21, .poster)
        XCTAssertNil(missing)
    }

    func testOfflineTheDownloadedAlbumsAndArtistsFileUnderTheirLetters() async throws {
        harness.goOffline()
        let music = MusicModel(client: harness.client, profileId: 1)
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
        for target in [DownloadTarget.show(10), .title(20), .title(5), .title(70)] {
            store.remove(target, profile: 1)
        }
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
        let custom = await art.data(imageUrl: "/api/v1/stations/5/image?v=9")
        XCTAssertNil(custom)
        XCTAssertEqual(generation.value, 3)
        XCTAssertEqual(store.titles[20]?.state, .onDevice)
        let again = await art.data(20, .poster)
        XCTAssertEqual(again, Data("jpeg".utf8))
    }

    func testAnotherProfileSeesNoneOfIt() async {
        harness.goOffline()
        let model = CatalogModel(client: harness.client, profileId: 2)
        harness.store.ledger.shelf.me?.activeProfileId = 2
        await model.load()
        XCTAssertTrue(model.catalog.items.isEmpty)
    }

    func testTheAppOpensOfflineOnWhatIsDownloaded() async throws {
        harness.goOffline()
        let credentials = MemoryCredentialStore()
        credentials.server = harness.endpoint.baseURL
        credentials.token = "tok-1"
        let app = AppModel(
            store: credentials, deviceName: "Mac", transport: harness.transport, downloads: harness.store)
        await app.restore()
        XCTAssertEqual(app.phase, .choosingProfile)
        try await app.choose(try XCTUnwrap(app.profiles.first { $0.id == 1 }))
        XCTAssertEqual(app.phase, .browsing)
        do {
            try await app.choose(try XCTUnwrap(app.profiles.first { $0.id == 2 }), pin: "1234")
            XCTFail("a PIN can't be checked offline")
        } catch {}
    }

    func testWithNothingDownloadedTheServerIsUnreachableAsBefore() async {
        harness.store.wipe()
        harness.goOffline()
        let credentials = MemoryCredentialStore()
        credentials.server = harness.endpoint.baseURL
        credentials.token = "tok-1"
        let app = AppModel(
            store: credentials, deviceName: "Mac", transport: harness.transport, downloads: harness.store)
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

    func testWithNothingDownloadedTheCatalogKeepsWhatItHadWhenTheServerGoes() async {
        harness.store.wipe()
        harness.transport.routes["GET /items"] = (.ok, Fixtures.page([Fixtures.item(20, "movie", "Dune")]))
        harness.transport.routes["GET /profiles/1/watch-state"] = (.ok, Fixtures.page([]))
        let model = CatalogModel(client: harness.client, profileId: 1)
        await model.load()
        XCTAssertNotNil(model.catalog.item(20))

        harness.goOffline()
        await model.load()
        XCTAssertNotNil(model.catalog.item(20))
        XCTAssertNotNil(model.error)
    }

    func testThePlayerPlaysTheFileAndUpNextIsTheNextDownloadedEpisode() async throws {
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

        let profile = Fixtures.decode(Fixtures.adult, as: Account.self)
        let next = await UpNextModel.load(after: PlayRequest(item: item), client: harness.client, profile: profile)
        XCTAssertEqual(next?.request.item.id, 103)
        XCTAssertEqual(next?.title, "Severance · S1 E3 · In Perpetuity")
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
        func play(edition: Int64) async -> URL? {
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
