import Foundation
import RabbitEarsAPI
import XCTest

@testable import RabbitEarsKit

@MainActor
private final class Screen: VideoBrowser {
    var playing: PlayRequest?
}

/// Two seasons and specials, one episode watched, one in progress and one whose file is gone.
private func show(gone: Set<UID> = [202]) -> Catalog {
    let items = [
        Fixtures.item(10, "show", "Severance"),
        Fixtures.item(11, "season", "Season 1", parent: 10, season: 1),
        Fixtures.item(12, "season", "Season 2", parent: 10, season: 2),
        Fixtures.item(13, "season", "Specials", parent: 10, season: 0),
        Fixtures.item(101, "episode", "Good News", parent: 11, season: 1, episode: 1),
        Fixtures.item(102, "episode", "Half Loop", parent: 11, season: 1, episode: 2),
        Fixtures.item(201, "episode", "Hello", parent: 12, season: 2, episode: 1),
        Fixtures.item(202, "episode", "Goodbye", parent: 12, season: 2, episode: 2),
        Fixtures.item(203, "episode", "Woe", parent: 12, season: 2, episode: 3),
        Fixtures.item(301, "episode", "Inside", parent: 13, season: 0, episode: 1),
    ].map {
        var item = Fixtures.decode($0, as: Item.self)
        if gone.contains(item.id) { item.unavailable = true }
        return item
    }
    return Catalog(
        items: items,
        watch: [Fixtures.watch(101, watched: true), Fixtures.watch(201, position: 600_000)].map {
            Fixtures.decode($0, as: WatchState.self)
        })
}

@MainActor
final class ShuffleTests: XCTestCase {
    func testAShowShufflesEveryEpisodeWithAFileInOneFlatOrder() throws {
        let catalog = show()
        let queue = try XCTUnwrap(VideoQueue(shuffling: catalog.episodes(under: 10), order: { $0.reversed() }))
        XCTAssertEqual(
            queue.items.map(\.id), [301, 203, 201, 102, 101],
            "across seasons, specials and watched or started episodes included, the gone one left out")
        XCTAssertNil(queue.playlistId)
        XCTAssertEqual(queue.index, 0)
        XCTAssertNil(queue.editionId, "the default edition")

        let random = try XCTUnwrap(VideoQueue(shuffling: catalog.episodes(under: 10)))
        XCTAssertEqual(random.items.map(\.id).sorted(), [101, 102, 201, 203, 301])
    }

    func testASeasonShufflesOnlyItsOwnEpisodes() throws {
        let queue = try XCTUnwrap(VideoQueue(shuffling: show().episodes(under: 12), order: { $0.reversed() }))
        XCTAssertEqual(queue.items.map(\.id), [203, 201])
    }

    func testNothingWithAFileMakesNoShuffle() {
        XCTAssertNil(VideoQueue(shuffling: []))
        XCTAssertNil(VideoQueue(shuffling: show(gone: [101, 102]).episodes(under: 11)))
        let screen = Screen()
        screen.shuffle([], downloads: nil, profile: 1)
        XCTAssertNil(screen.playing)
    }

    func testAShuffleOfOneIsThatTitleAlone() throws {
        let movie = Fixtures.decode(Fixtures.item(20, "movie", "Dune"), as: Item.self)
        let queue = try XCTUnwrap(VideoQueue(shuffling: [movie]))
        XCTAssertEqual(queue.items.map(\.id), [20])
        XCTAssertNil(queue.next)
    }

    func testShufflePlaysItsFirstRowFromTheStartNotWhereItWasLeft() throws {
        let screen = Screen()
        let catalog = show()
        screen.shuffle(catalog.episodes(under: 12), downloads: nil, profile: 1, order: { $0.reversed() })
        let playing = try XCTUnwrap(screen.playing)
        XCTAssertEqual(playing.item.id, 203)
        XCTAssertEqual(playing.positionMs, 0, "an absent position would resume")
        XCTAssertNil(playing.editionId)
        XCTAssertNil(playing.together)
        XCTAssertNil(playing.queue?.playlistId)
    }

    func testNextInAShufflePlaysItsNextRowFromTheStartAndEndsAfterTheLast() throws {
        let screen = Screen()
        let catalog = show(gone: [])
        screen.shuffle(catalog.episodes(under: 12), downloads: nil, profile: 1, order: { $0.reversed() })
        let first = try XCTUnwrap(screen.playing)
        let second = try XCTUnwrap(first.shuffleNext(in: catalog))
        XCTAssertEqual(second.item.id, 202)
        XCTAssertEqual(second.positionMs, 0)
        XCTAssertEqual(second.id, first.id, "the same cover")
        let gone = try XCTUnwrap(first.shuffleNext(in: show()))
        XCTAssertEqual(gone.item.id, 201, "over a row whose file has gone since")
        XCTAssertEqual(gone.positionMs, 0, "a started episode starts again")
        XCTAssertNil(gone.shuffleNext(in: catalog), "the last row has nothing after it")
    }

    func testAPlaylistsNextIsNotAShufflesNext() throws {
        let rows = [Fixtures.row(entry: 1, item: 20), Fixtures.row(entry: 2, item: 21)]
            .map { Fixtures.decode($0, as: PlayOrderRow.self) }
        let queue = try XCTUnwrap(VideoQueue(rows, start: 0, playlistId: 3))
        XCTAssertNil(PlayRequest(item: queue.current, queue: queue).shuffleNext(in: show()))
    }
}

extension OfflineBrowseTests {
    func testOfflineAShuffleHoldsOnlyWhatIsOnTheDevice() async throws {
        let episodes = [101, 102, 103].map {
            Fixtures.decode(Fixtures.item(.n($0), "episode", "E\($0)", parent: 11), as: Item.self)
        }
        let screen = Screen()
        screen.shuffle(episodes, downloads: store, profile: 1, order: { $0 })
        XCTAssertEqual(screen.playing?.queue?.items.map(\.id), [101, 102, 103], "online, the whole scope")

        harness.goOffline()
        _ = try? await harness.client.listItems(query: .init(kind: .episode)).ok
        screen.shuffle(episodes, downloads: store, profile: 1, order: { $0 })
        XCTAssertEqual(screen.playing?.queue?.items.map(\.id), [101, 103])
    }
}
