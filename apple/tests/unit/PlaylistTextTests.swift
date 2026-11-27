import Foundation
import RabbitEarsAPI
import XCTest

@testable import RabbitEarsKit

extension PlaylistsModelTests {
    func testAVideoQueueWalksThePlayOrderAndStopsAtTheEnd() throws {
        let rows = [
            Fixtures.row(entry: 1, item: 20), Fixtures.row(entry: 2, item: 21), Fixtures.row(entry: 2, item: 22),
        ]
        .map { Fixtures.decode($0, as: PlayOrderRow.self) }
        let queue = try XCTUnwrap(VideoQueue(rows, start: try XCTUnwrap(rows.start(of: 2)), playlistId: 3))
        XCTAssertEqual(queue.current.id, 21)
        XCTAssertEqual(queue.playlistId, 3)
        let next = try XCTUnwrap(queue.next)
        XCTAssertEqual(next.current.id, 22)
        XCTAssertNil(next.next)
        XCTAssertNil(VideoQueue([], start: 0, playlistId: 3))
    }

    func testEachQueuedRowPlaysItsOwnEditionAndNamesItWhenThereIsAChoice() throws {
        let rows = [
            Fixtures.row(
                entry: 1, item: 20, kind: "movie", edition: #","editionId":"\#(UID.n(6))","editionName":"Extended""#),
            Fixtures.row(entry: 2, item: 21, kind: "movie", edition: #","editionId":"\#(UID.n(8))""#),
            Fixtures.row(entry: 3, item: 22),
        ]
        .map { Fixtures.decode($0, as: PlayOrderRow.self) }
        let queue = try XCTUnwrap(VideoQueue(rows, start: 0, playlistId: 3))
        XCTAssertEqual(queue.editionId, 6)
        XCTAssertEqual(PlaylistText.named("Item 20", edition: queue.editionName), "Item 20 · Extended")
        let second = try XCTUnwrap(queue.next)
        XCTAssertEqual(second.editionId, 8)
        XCTAssertEqual(PlaylistText.named("Item 21", edition: second.editionName), "Item 21")
        XCTAssertNil(second.next?.editionId)
    }

    func testAnEntryOfOneOfSeveralEditionsNamesIt() {
        let movie: PlaylistEntry = Fixtures.decode(
            Fixtures.entry(
                1, position: 0, kind: "movie", itemId: 9,
                objects: #""item":\#(Fixtures.item(9, "movie", "Ferrous Tide")),"editionId":"\#(UID.n(6))","#
                    + #""editionName":"Extended""#
            ))
        XCTAssertEqual(PlaylistText.title(movie), "Ferrous Tide · Extended")
    }

    func testAPlaylistTakesItsKindFromTheItem() {
        XCTAssertEqual(PlaylistKind(holding: .movie), .movies)
        XCTAssertEqual(PlaylistKind(holding: .show), .tv)
        XCTAssertEqual(PlaylistKind(holding: .season), .tv)
        XCTAssertEqual(PlaylistKind(holding: .episode), .tv)
    }

    func testSummariesCountWhatThePlayOrderPlays() {
        func summary(_ kind: String, _ count: Int, _ ms: Int64) -> String {
            PlaylistText.summary(Fixtures.decode(Fixtures.playlist(1, "P", kind: kind, count: count, durationMs: ms)))
        }
        XCTAssertEqual(summary("movies", 3, 22_200_000), "3 movies · 6h 10m")
        XCTAssertEqual(summary("tv", 1, 1_800_000), "1 episode · 30m")
        XCTAssertEqual(summary("music", 48, 10_920_000), "48 songs · 3h 2m")
    }

    func testAContainerEntryIsOneRowSayingWhatItStandsFor() {
        func entry(_ kind: String, _ objects: String, count: Int = 1, ms: Int64 = 0) -> PlaylistEntry {
            Fixtures.decode(
                Fixtures.entry(1, position: 0, kind: kind, itemId: 9, objects: objects, count: count, durationMs: ms))
        }
        let show = #""show":\#(Fixtures.item(70, "show", "Severance"))"#
        let movie = entry("movie", #""item":\#(Fixtures.item(9, "movie", "Dune"))"#, ms: 9_960_000)
        XCTAssertEqual(PlaylistText.title(movie), "Dune")
        XCTAssertEqual(PlaylistText.detail(movie), "2h 46m")
        XCTAssertEqual(movie.artId, 9)

        let series = entry("show", #""item":\#(Fixtures.item(9, "show", "Severance"))"#, count: 12)
        XCTAssertEqual(PlaylistText.detail(series), "12 episodes")
        let season = entry(
            "season", #""item":\#(Fixtures.item(9, "season", "Season 2", parent: 70)),\#(show)"#, count: 10)
        XCTAssertEqual(PlaylistText.title(season), "Season 2")
        XCTAssertEqual(PlaylistText.detail(season), "Severance · 10 episodes")
        let episode = entry(
            "episode", #""item":\#(Fixtures.item(9, "episode", "Hello", parent: 71, season: 1, episode: 3)),\#(show)"#)
        XCTAssertEqual(PlaylistText.detail(episode), "Severance · S1 E3")

        let artist = entry("artist", #""artist":\#(Fixtures.artist)"#, count: 112)
        XCTAssertEqual(PlaylistText.title(artist), "Radiohead")
        XCTAssertEqual(PlaylistText.detail(artist), "112 songs")
        let album = entry("album", #""album":\#(Fixtures.album(50, "In Rainbows"))"#, count: 9)
        XCTAssertEqual(PlaylistText.title(album), "In Rainbows")
        XCTAssertEqual(PlaylistText.detail(album), "Radiohead · 9 songs")
        let song = entry("song", #""song":\#(Fixtures.song(9, "Nude", album: 50))"#)
        XCTAssertEqual(PlaylistText.title(song), "Nude")
        XCTAssertEqual(PlaylistText.detail(song), "Radiohead · In Rainbows")
        XCTAssertEqual(song.artId, 50, "a song's art is its album's")

        let collection: PlaylistEntry = Fixtures.decode(Fixtures.entry(1, position: 0, collection: 6, count: 3))
        XCTAssertEqual(PlaylistText.title(collection), "Comet saga")
        XCTAssertEqual(PlaylistText.detail(collection), "3 movies")
        XCTAssertEqual(collection.artId, 6, "a collection's art is its own")
    }
}
