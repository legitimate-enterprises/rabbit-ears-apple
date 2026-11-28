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
        XCTAssertEqual(
            catalog.continueWatching(with: [video]).map(\.id),
            ["item/\(UID.n(102))", "video/\(UID.n(70))", "item/\(UID.n(20))"])
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

    func testTheResumeBarIsWhatPlayResumes() {
        let catalog = sampleCatalog(watch: [
            Fixtures.watch(20, position: 4_980_000, edition: 7),
            Fixtures.watch(21, watched: true),
            Fixtures.watch(101, watched: true, played: "2026-05-01T00:00:00Z"),
            Fixtures.watch(102, position: 1_500_000, played: "2026-05-02T00:00:00Z"),
        ])
        XCTAssertEqual(catalog.resumeProgress(20) ?? 0, 0.5, accuracy: 0.001)
        XCTAssertEqual(catalog.resumeProgress(20, edition: 7) ?? 0, 0.5, accuracy: 0.001)
        XCTAssertNil(catalog.resumeProgress(20, edition: 8), "another cut starts at the top")
        XCTAssertNil(catalog.resumeProgress(21), "finished")
        XCTAssertNil(catalog.resumeProgress(22), "never started")
        XCTAssertEqual(catalog.resumeProgress(102) ?? 0, 0.5, accuracy: 0.001)
        XCTAssertEqual(catalog.resumeProgress(10) ?? 0, 0.5, accuracy: 0.001, "the show resumes S1 E2")
        XCTAssertEqual(catalog.resumeProgress(11) ?? 0, 0.5, accuracy: 0.001)
        XCTAssertNil(catalog.resumeProgress(12), "season 2 starts E1 from the top")
    }

    func testAShowWhoseNextEpisodeIsUnstartedHasNoResumeBar() {
        let catalog = sampleCatalog(watch: [
            Fixtures.watch(101, watched: true, played: "2026-05-01T00:00:00Z"),
            Fixtures.watch(102, watched: true, played: "2026-05-02T00:00:00Z"),
        ])
        XCTAssertEqual(catalog.resumeTarget(for: 10)?.id, 201)
        XCTAssertNil(catalog.resumeProgress(10))
        XCTAssertNil(catalog.resumeProgress(11))
    }

    func testAPlaylistRowResumesOnlyAMovieOrEpisodeInItsOwnEdition() {
        let catalog = sampleCatalog(watch: [
            Fixtures.watch(20, position: 4_980_000, edition: 7),
            Fixtures.watch(102, position: 1_500_000),
        ])
        func entry(_ kind: String, _ item: UID, edition: UID? = nil) -> PlaylistEntry {
            let cut = edition.map { #","editionId":"\#($0)""# } ?? ""
            return Fixtures.decode(
                Fixtures.entry(
                    1, position: 0, kind: kind, itemId: item,
                    objects: #""item":\#(Fixtures.item(item, kind, "Item"))\#(cut)"#))
        }
        XCTAssertEqual(catalog.resumeProgress(entry("movie", 20, edition: 7)) ?? 0, 0.5, accuracy: 0.001)
        XCTAssertNil(catalog.resumeProgress(entry("movie", 20, edition: 8)))
        XCTAssertEqual(catalog.resumeProgress(entry("episode", 102)) ?? 0, 0.5, accuracy: 0.001)
        XCTAssertNil(catalog.resumeProgress(entry("show", 10)), "a show's row plays from its first row")
    }

    func testAVideoResumesOnlyFromAPosition() {
        func video(position: Int64, watched: Bool = false) -> YouTubeVideo {
            Fixtures.decode(Fixtures.video(70, "Dishwasher", watched: watched, position: position))
        }
        XCTAssertEqual(video(position: 1_260_000).progress ?? 0, 0.5, accuracy: 0.001)
        XCTAssertNil(video(position: 0).progress)
        XCTAssertNil(video(position: 0, watched: true).progress)
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
        XCTAssertEqual(one?.hero.id, "item/\(UID.n(20))")
        XCTAssertEqual(one?.alsoInProgress.map(\.id), [])
        let several = HomeHero(items)
        XCTAssertEqual(several?.hero.id, "item/\(UID.n(20))")
        XCTAssertEqual(several?.alsoInProgress.map(\.id), ["item/\(UID.n(21))", "item/\(UID.n(22))"])
    }

    func testTheChipsAreAllUnwatchedInProgressFavoritesAndKids() {
        XCTAssertEqual(
            GridFilter.allCases.map(\.rawValue), ["All", "Unwatched", "In progress", "Favorites", "Kids"])
    }

    func testTheFavoritesChipKeepsTheStarredTitlesOfTheKind() {
        let catalog = sampleCatalog()
        let starred = catalog.grid(.movie, filter: .favorites, sort: .title, favorites: [22, 20, 10])
        XCTAssertEqual(starred.map(\.id), [22, 20])
        XCTAssertEqual(catalog.grid(.movie, filter: .favorites).map(\.id), [])
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
