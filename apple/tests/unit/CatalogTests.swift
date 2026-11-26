import Foundation
import RabbitEarsAPI
import XCTest

@testable import RabbitEarsKit

/// One show with two seasons plus specials, two movies.
private func sampleCatalog(watch: [String] = []) -> Catalog {
    let items = [
        Fixtures.item(10, "show", "Severance", added: "2026-03-01T00:00:00Z", runtime: 50, rating: "TV-MA"),
        Fixtures.item(11, "season", "Season 1", parent: 10, season: 1),
        Fixtures.item(12, "season", "Season 2", parent: 10, season: 2),
        Fixtures.item(13, "season", "Specials", parent: 10, season: 0),
        Fixtures.item(101, "episode", "Good News", parent: 11, season: 1, episode: 1, runtime: 50),
        Fixtures.item(102, "episode", "Half Loop", parent: 11, season: 1, episode: 2, runtime: 50),
        Fixtures.item(201, "episode", "Hello", parent: 12, season: 2, episode: 1, runtime: 50),
        Fixtures.item(202, "episode", "Goodbye", parent: 12, season: 2, episode: 2, runtime: 50),
        Fixtures.item(301, "episode", "Inside", parent: 13, season: 0, episode: 1),
        Fixtures.item(
            20, "movie", "Dune", added: "2026-02-01T00:00:00Z", runtime: 166, rating: "PG-13", year: 2024,
            genres: [(878, "Science Fiction"), (12, "Adventure")]),
        Fixtures.item(
            21, "movie", "Arrival", added: "2026-04-01T00:00:00Z", runtime: 116, rating: "PG-13", year: 2016,
            genres: [(878, "Science Fiction")]),
        Fixtures.item(
            22, "movie", "Bluey Movie", added: "2026-01-01T00:00:00Z", runtime: 60, rating: "G", year: 2025,
            kids: true),
    ].map { Fixtures.decode($0, as: Item.self) }
    return Catalog(
        items: items, watch: watch.map { Fixtures.decode($0, as: Components.Schemas.WatchState.self) })
}

final class CatalogTests: XCTestCase {
    func testChildrenAreInNumberOrderWithSpecialsLast() {
        let catalog = sampleCatalog()
        XCTAssertEqual(catalog.children(of: 10).map(\.id), [11, 12, 13])
        XCTAssertEqual(catalog.children(of: 12).map(\.id), [201, 202])
        XCTAssertEqual(catalog.show(of: catalog.item(202)!)?.id, 10)
        XCTAssertEqual(catalog.episodes(under: 10).map(\.id), [101, 102, 201, 202, 301])
    }

    func testUnwatchedCountsEpisodesNotSeasons() {
        let catalog = sampleCatalog(watch: [Fixtures.watch(101, watched: true), Fixtures.watch(102, position: 9)])
        XCTAssertEqual(catalog.unwatchedCount(10), 4)
        XCTAssertEqual(catalog.unwatchedCount(11), 1)
        XCTAssertEqual(catalog.unwatchedCount(20), 1)
        XCTAssertTrue(catalog.isWatched(101))
    }

    func testContinueWatchingIsInProgressByLastPlayed() {
        let catalog = sampleCatalog(watch: [
            Fixtures.watch(20, position: 60_000, played: "2026-05-01T00:00:00Z"),
            Fixtures.watch(102, position: 1_500_000, played: "2026-05-03T00:00:00Z"),
            Fixtures.watch(21, position: 0, watched: true, played: "2026-05-04T00:00:00Z"),
        ])
        XCTAssertEqual(catalog.continueWatching.map(\.id), [102, 20])
        XCTAssertEqual(catalog.progress(102) ?? 0, 0.5, accuracy: 0.001)
        XCTAssertEqual(catalog.remainingMs(102), 1_500_000)
    }

    func testAWatchedTitlePlayedAgainPartwayIsInProgress() {
        let catalog = sampleCatalog(watch: [Fixtures.watch(20, position: 60_000, watched: true)])
        XCTAssertTrue(catalog.isInProgress(20))
        XCTAssertEqual(catalog.continueWatching.map(\.id), [20])
        XCTAssertEqual(catalog.remainingMs(20), 9_900_000)
    }

    func testContinueWatchingMergesVideosByLastPlayed() {
        let catalog = sampleCatalog(watch: [
            Fixtures.watch(20, position: 60_000, played: "2026-05-01T00:00:00Z"),
            Fixtures.watch(102, position: 60_000, played: "2026-05-03T00:00:00Z"),
        ])
        let video = Fixtures.decode(
            Fixtures.video(70, "Dishwasher", position: 9, played: "2026-05-02T00:00:00Z"), as: YouTubeVideo.self)
        XCTAssertEqual(catalog.continueWatching(with: [video]).map(\.id), ["item/102", "video/70", "item/20"])
    }

    func testNextUpFollowsTheLatestWatchedEpisodeAcrossSeasons() {
        let catalog = sampleCatalog(watch: [
            Fixtures.watch(101, watched: true, played: "2026-05-01T00:00:00Z"),
            Fixtures.watch(102, watched: true, played: "2026-05-02T00:00:00Z"),
        ])
        XCTAssertEqual(catalog.nextUp.map(\.id), [201])
        XCTAssertEqual(catalog.resumeTarget(for: 10)?.id, 201)
        XCTAssertEqual(sampleCatalog().resumeTarget(for: 10)?.id, 101)
        XCTAssertEqual(sampleCatalog().resumeTarget(for: 12)?.id, 201)
    }

    func testAShowInProgressResumesItsEpisode() {
        let catalog = sampleCatalog(watch: [
            Fixtures.watch(101, watched: true, played: "2026-05-01T00:00:00Z"),
            Fixtures.watch(102, position: 5, played: "2026-05-02T00:00:00Z"),
        ])
        XCTAssertEqual(catalog.resumeTarget(for: 10)?.id, 102)
        XCTAssertTrue(catalog.nextUp.isEmpty)
    }

    func testRecentlyAddedIsMoviesAndShowsNewestFirst() {
        XCTAssertEqual(sampleCatalog().recentlyAdded.map(\.id), [21, 10, 20, 22])
    }

    func testGridFiltersSortsAndSearches() {
        let catalog = sampleCatalog(watch: [Fixtures.watch(20, watched: true)])
        XCTAssertEqual(catalog.grid(.movie, sort: .title).map(\.id), [21, 22, 20])
        XCTAssertEqual(catalog.grid(.movie, sort: .recentlyAdded).map(\.id), [21, 20, 22])
        XCTAssertEqual(catalog.grid(.movie, sort: .year).map(\.id), [22, 20, 21])
        XCTAssertEqual(catalog.grid(.movie, filter: .unwatched, sort: .title).map(\.id), [21, 22])
        XCTAssertEqual(catalog.grid(.movie, filter: .kids, sort: .title).map(\.id), [22])
        XCTAssertEqual(catalog.grid(.movie, sort: .title, genre: 878).map(\.id), [21, 20])
        XCTAssertEqual(catalog.grid(.movie, genre: 12).map(\.id), [20])
        XCTAssertEqual(catalog.genres(.movie).map(\.name), ["Adventure", "Science Fiction"])
        XCTAssertEqual(catalog.genres(.show), [])
        XCTAssertEqual(catalog.grid(.show, filter: .unwatched).map(\.id), [10])
        XCTAssertEqual(catalog.grid(.show, filter: .inProgress).map(\.id), [])
    }

    func testTheKidsChipIsTheServersFlagNotARating() {
        let items = [
            Fixtures.item(40, "show", "Marked", rating: "TV-MA", kids: true),
            Fixtures.item(41, "show", "Unmarked", rating: "TV-Y", kids: false),
            Fixtures.item(42, "show", "Unknown", rating: "TV-Y"),
        ].map { Fixtures.decode($0, as: Item.self) }
        XCTAssertEqual(Catalog(items: items).grid(.show, filter: .kids).map(\.id), [40])
    }

    func testTheHeroIsOnlyWhatIsInProgressWithTheRestBesideIt() {
        let items = [20, 21, 22].map { Resumable.item(Fixtures.decode(Fixtures.item($0, "movie", "M\($0)"))) }
        XCTAssertNil(HomeHero(Array(items.prefix(0))), "nothing in progress has no hero")
        let one = HomeHero(Array(items.prefix(1)))
        XCTAssertEqual(one?.hero.id, "item/20")
        XCTAssertEqual(one?.alsoInProgress.map(\.id), [])
        let several = HomeHero(items)
        XCTAssertEqual(several?.hero.id, "item/20")
        XCTAssertEqual(several?.alsoInProgress.map(\.id), ["item/21", "item/22"])
    }

    func testTheChipsAreAllUnwatchedInProgressAndKids() {
        XCTAssertEqual(GridFilter.allCases.map(\.rawValue), ["All", "Unwatched", "In progress", "Kids"])
    }
}

@MainActor
final class CatalogModelTests: XCTestCase {
    func testLoadsEveryKindAndPageAsTheProfile() async throws {
        let transport = RoutingTransport([
            "GET /items": (.ok, Fixtures.page([Fixtures.item(20, "movie", "Dune")])),
            "GET /profiles/2/watch-state": (.ok, Fixtures.page([Fixtures.watch(20, watched: true)])),
            "PUT /profiles/2/watch-state/20": (.ok, Fixtures.watch(20, watched: false)),
        ])
        let model = CatalogModel(client: ServerEndpoint.default.client(token: "t", transport: transport), profileId: 2)
        await model.load()
        XCTAssertNil(model.error)
        XCTAssertEqual(transport.paths(.get).filter { $0 == "/items" }.count, 4)
        XCTAssertTrue(model.catalog.isWatched(20))
        await model.setWatched(false, for: model.catalog.item(20)!)
        XCTAssertFalse(model.catalog.isWatched(20))
        XCTAssertEqual(transport.json(.put, "/profiles/2/watch-state/20")?["watched"] as? Bool, false)
    }

    func testASignedOutDeviceSaysSoRatherThanBlamingThePassword() async throws {
        let transport = RoutingTransport([
            "GET /items": (.unauthorized, Fixtures.error("unauthorized")),
            "PUT /profiles/2/watch-state/20": (.unauthorized, Fixtures.error("unauthorized")),
        ])
        let client = ServerEndpoint.default.client(token: "t", transport: transport)
        let loading = CatalogModel(client: client, profileId: 2)
        await loading.load()
        XCTAssertEqual(loading.error, "Signed out.")
        let marking = CatalogModel(client: client, profileId: 2)
        await marking.setWatched(true, for: Fixtures.decode(Fixtures.item(20, "movie", "Dune"), as: Item.self))
        XCTAssertEqual(marking.error, "Signed out.")
    }

    func testLoadAsksForEveryKindAndTheWatchStateAtOnce() async throws {
        let transport = RoutingTransport([
            "GET /items": (.ok, Fixtures.page([])),
            "GET /profiles/2/watch-state": (.ok, Fixtures.page([])),
        ])
        let inFlight = InFlight()
        transport.hold = { _ in await inFlight.arriveAndWait(for: 5) }
        let model = CatalogModel(client: ServerEndpoint.default.client(token: "t", transport: transport), profileId: 2)
        await model.load()
        let peak = await inFlight.peak
        XCTAssertEqual(peak, 5)
    }

    func testALaterLoadStandsOverAnEarlierOneThatAnswersAfterIt() async throws {
        let dune = Fixtures.page([Fixtures.item(1, "movie", "Dune")])
        let transport = RoutingTransport([
            "GET /items": (.ok, dune),
            "GET /profiles/2/watch-state": (.ok, Fixtures.page([])),
        ])
        let gate = FirstLoadGate()
        transport.hold = { _ in await gate.pass() }
        let model = CatalogModel(client: ServerEndpoint.default.client(token: "t", transport: transport), profileId: 2)
        let first = Task { await model.load() }
        while await gate.waiting < 5 { try await Task.sleep(for: .milliseconds(5)) }
        transport.routes["GET /items"] = (.ok, Fixtures.page([Fixtures.item(2, "movie", "Flow")]))
        await model.load()
        XCTAssertNotNil(model.catalog.item(2))
        transport.routes["GET /items"] = (.ok, dune)
        await gate.release()
        await first.value
        XCTAssertNotNil(model.catalog.item(2))
        XCTAssertNil(model.catalog.item(1))
    }

    func testAfterPlayTheServersWatchStateStands() async throws {
        let transport = RoutingTransport([
            "GET /items": (.ok, Fixtures.page([Fixtures.item(20, "movie", "Dune")])),
            "GET /profiles/2/watch-state": (.ok, Fixtures.page([Fixtures.watch(20, position: 60_000)])),
            "GET /profiles/2/watch-state/20": (.ok, Fixtures.watch(20, position: 0, watched: true)),
        ])
        let model = CatalogModel(client: ServerEndpoint.default.client(token: "t", transport: transport), profileId: 2)
        await model.load()
        XCTAssertTrue(model.catalog.isInProgress(20))
        await model.refreshWatchState(20)
        XCTAssertTrue(model.catalog.isWatched(20))
        XCTAssertFalse(model.catalog.isInProgress(20))
    }

    func testPlayabilitySendsThePlayersSnapshotAndReadsTheVerdict() async throws {
        let transport = RoutingTransport([
            "POST /items/20/playability": (
                .ok,
                #"{"verdict":"video_transcode","negotiated":{"verdict":"video_transcode","width":1920,"#
                    + #""height":1080,"bitrate":8000000,"encoder":"hardware"}}"#
            )
        ])
        let model = CatalogModel(client: ServerEndpoint.default.client(token: "t", transport: transport), profileId: 2)
        let facts = FakeCapabilities().current
        let result = await model.playability(20, facts: facts, server: .default)
        XCTAssertEqual(result?.verdict, .videoTranscode)
        XCTAssertEqual(Format.playability(try XCTUnwrap(result?.verdict)), "Transcode on this device")
        XCTAssertEqual(Format.playability(.directPlay), "Direct play on this device")
        let sent = Fixtures.decode(
            try XCTUnwrap(transport.body(.post, "/items/20/playability")), as: CapabilitySnapshot.self)
        XCTAssertEqual(sent, CapabilitySnapshotBuilder.snapshot(facts, server: .default, maxBitrate: nil))
        transport.routes["POST /items/20/playability"] = (.conflict, Fixtures.error("conflict"))
        let none = await model.playability(20, facts: facts, server: .default)
        XCTAssertNil(none)
    }

    func testSearchIsOneAskWithASectionPerListThatFoundAnything() async throws {
        let found =
            #"{"movies":[\#(Fixtures.item(20, "movie", "Dune"))],"#
            + #""shows":[\#(Fixtures.item(30, "show", "Dune Show"))],"#
            + #""episodes":[\#(Fixtures.item(31, "episode", "Dune Day", parent: 30))],"#
            + #""people":[{"id":5,"name":"Denis Villeneuve"}],"artists":[],"albums":[],"#
            + #""songs":[\#(Fixtures.song(40, "Dune Song"))],"channels":[],"videos":[]}"#
        let transport = RoutingTransport(["GET /search": (.ok, found)])
        let model = CatalogModel(client: ServerEndpoint.default.client(token: "t", transport: transport), profileId: 2)
        let empty = await model.search("  ")
        XCTAssertEqual(empty, .empty)
        XCTAssertTrue(transport.sent.isEmpty)
        let searched = await model.search(" dune ")
        let result = try XCTUnwrap(searched)
        XCTAssertEqual(result.sections, [.movies, .tv, .songs, .people])
        XCTAssertEqual(result.sections.map(\.rawValue), ["Movies", "TV", "Songs", "People"])
        XCTAssertEqual(result.tv.map(\.id), [31, 30])
        XCTAssertEqual(transport.queries(.get, "/search"), ["q=dune&limit=20"])
        XCTAssertEqual(SearchSection.allCases.count, 8)
        transport.routes["GET /search"] = (.internalServerError, Fixtures.error("internal"))
        let failed = await model.search("dune")
        XCTAssertNil(failed)
    }

    func testKidsContentIsOverriddenThenLeftToTheRating() async throws {
        let dune = Fixtures.item(20, "movie", "Dune", rating: "PG-13")
        let marked = String(dune.dropLast()) + #","kidsContent":true,"kidsContentOverride":true}"#
        let transport = RoutingTransport([
            "PUT /items/20/kids-content": (.ok, marked),
            "DELETE /items/20/kids-content": (.noContent, ""),
            "GET /items/20": (.ok, String(dune.dropLast()) + #","kidsContent":false}"#),
        ])
        let model = CatalogModel(client: ServerEndpoint.default.client(token: "t", transport: transport), profileId: 2)
        let item = Fixtures.decode(dune, as: Item.self)
        await model.setKidsContent(true, for: item)
        XCTAssertEqual(transport.json(.put, "/items/20/kids-content")?["kidsContent"] as? Bool, true)
        XCTAssertEqual(model.catalog.item(20)?.kidsContent, true)
        XCTAssertEqual(model.catalog.item(20)?.kidsContentOverride, true)
        await model.setKidsContent(nil, for: item)
        XCTAssertEqual(transport.paths(.delete), ["/items/20/kids-content"])
        XCTAssertEqual(model.catalog.item(20)?.kidsContent, false)
        XCTAssertNil(model.catalog.item(20)?.kidsContentOverride)
        XCTAssertNil(model.error)
    }

    func testCreditsAndAPersonsTitles() async throws {
        let transport = RoutingTransport([
            "GET /items/20/credits": (
                .ok,
                #"{"cast":[{"personId":5,"name":"Zendaya","character":"Chani","profilePath":"/z.jpg"}],"#
                    + #""crew":[{"personId":6,"name":"Denis Villeneuve","job":"Director"}]}"#
            ),
            "GET /people/5": (.ok, #"{"id":5,"name":"Zendaya"}"#),
            "GET /items": (.ok, Fixtures.page([Fixtures.item(20, "movie", "Dune")])),
        ])
        let model = CatalogModel(client: ServerEndpoint.default.client(token: "t", transport: transport), profileId: 2)
        let loaded = await model.credits(20)
        let credits = try XCTUnwrap(loaded)
        XCTAssertEqual(credits.cast.first?.character, "Chani")
        XCTAssertEqual(credits.crew.first?.job, "Director")
        let found = await model.person(5)
        XCTAssertEqual(found?.0.name, "Zendaya")
        XCTAssertEqual(found?.1.map(\.id), [20])
        XCTAssertEqual(transport.queries(.get, "/items"), ["personId=5&limit=200"])
    }

    func testCrewLinesNameEachJobOnceInCreditOrder() {
        let credits = Fixtures.decode(
            #"{"cast":[],"crew":[{"personId":1,"name":"Ann","job":"Writer"},"#
                + #"{"personId":2,"name":"Bo","job":"Director"},{"personId":3,"name":"Cy","job":"Writer"},"#
                + #"{"personId":4,"name":"Di"}]}"#, as: Credits.self)
        let lines = credits.crewLines
        XCTAssertEqual(lines.map(\.0), ["Writer", "Director", "Crew"])
        XCTAssertEqual(lines.map(\.1), ["Ann, Cy", "Bo", "Di"])
    }
}

final class FormatTests: XCTestCase {
    func testCountNamesOneInTheSingularAndTheRestInThePlural() {
        XCTAssertEqual(Format.count(0, "title"), "0 titles")
        XCTAssertEqual(Format.count(1, "title"), "1 title")
        XCTAssertEqual(Format.count(1210, "album"), "1210 albums")
    }

    func testRuntimeLeadsWithHours() {
        XCTAssertEqual(Format.runtime(minutes: 166), "2h 46m")
        XCTAssertEqual(Format.runtime(minutes: 50), "50m")
        XCTAssertEqual(Format.runtime(minutes: 120), "2h")
        XCTAssertEqual(Format.remaining(ms: 1_380_000), "23m left")
        XCTAssertEqual(Format.remaining(ms: 4_320_000), "1h 12m left")
    }

    func testBitrateAndResolution() {
        XCTAssertEqual(Format.bitrate(38_000_000), "38 Mb/s")
        XCTAssertEqual(Format.bitrate(1_500_000), "1.5 Mb/s")
        XCTAssertEqual(Format.bitrate(800_000), "800 kb/s")
        XCTAssertEqual(Format.resolution(width: 3840, height: 1600), "4K")
        XCTAssertEqual(Format.resolution(width: 1920, height: 1080), "1080p")
        XCTAssertEqual(Format.resolution(width: 1280, height: 534), "720p")
        XCTAssertEqual(Format.resolution(width: 854, height: 480), "480p")
    }

    func testPillReadsWhatWasNegotiated() {
        let hdr = Components.Schemas.Negotiated(
            verdict: .directPlay, width: 3840, height: 2160, hdrFormat: .hdr10, bitrate: 38_000_000)
        XCTAssertEqual(Format.pill(hdr), "4K HDR · Direct play · 38 Mb/s")
        let sdr = Components.Schemas.Negotiated(verdict: .videoTranscode, width: 1280, height: 720, bitrate: 4_000_000)
        XCTAssertEqual(Format.pill(sdr), "720p · Transcode · 4 Mb/s")
    }

    func testCaptionsLeadWithRuntime() {
        let catalog = sampleCatalog()
        XCTAssertEqual(catalog.caption(catalog.item(20)!), "2h 46m · 2024")
        XCTAssertEqual(catalog.caption(catalog.item(10)!), "50m · 2 seasons")
        XCTAssertEqual(Format.episodeCode(catalog.item(202)!), "S2 E2")
    }

    func testResumeTextNamesTheShowAndTimeLeft() {
        let catalog = sampleCatalog(watch: [Fixtures.watch(102, position: 1_500_000)])
        XCTAssertEqual(EpisodeText.line(catalog.item(102)!, catalog), "S1 E2 · Half Loop · 25m left")
        XCTAssertEqual(EpisodeText.line(catalog.item(20)!, catalog), "2h 46m · 2024")
        let episode = Resumable.item(catalog.item(102)!)
        XCTAssertEqual(episode.title(catalog), "Severance")
        XCTAssertEqual(episode.line(catalog), "S1 E2 · Half Loop · 25m left")
        XCTAssertEqual(episode.progress(catalog) ?? 0, 0.5, accuracy: 0.001)
        let video = Resumable.video(
            Fixtures.decode(Fixtures.video(70, "Dishwasher", position: 1_260_000), as: YouTubeVideo.self))
        XCTAssertEqual(video.title(catalog), "Dishwasher")
        XCTAssertEqual(video.line(catalog), "Workbench Weekly · 21m left")
        XCTAssertEqual(video.progress(catalog) ?? 0, 0.5, accuracy: 0.001)
    }

    func testLanguageNamesFromProbedCodes() {
        XCTAssertEqual(Format.language("eng"), "English")
        XCTAssertEqual(Format.language("spa"), "Spanish")
        XCTAssertEqual(Format.language(nil), "Unknown")
    }
}

/// Holds the first load's five requests until released; every later request passes.
private actor FirstLoadGate {
    private var arrived = 0
    private var held: [CheckedContinuation<Void, Never>] = []
    var waiting: Int { held.count }

    func pass() async {
        arrived += 1
        guard arrived <= 5 else { return }
        await withCheckedContinuation { held.append($0) }
    }

    func release() {
        for request in held { request.resume() }
        held = []
    }
}
