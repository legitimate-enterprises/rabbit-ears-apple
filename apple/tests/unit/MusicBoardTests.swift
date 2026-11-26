import Foundation
import RabbitEarsAPI
import XCTest

@testable import RabbitEarsKit

@MainActor
final class MusicBoardTests: XCTestCase {
    var transport: RoutingTransport!
    var board: MusicBoard!

    override func setUp() async throws {
        transport = RoutingTransport()
        board = MusicBoard(
            music: MusicModel(
                client: ServerEndpoint(userInput: "192.168.1.9")!.client(token: "t", transport: transport),
                profileId: 1))
    }

    func testAlbumsReadEveryPageWithTheChosenSortAndGenre() async {
        transport.respond = { sent in
            guard sent.path == "/music/albums" else { return nil }
            return sent.query.contains("offset=200")
                ? (.ok, Fixtures.page([Fixtures.album(51, "Kid A")], total: 2))
                : (.ok, #"{"items":[\#(Fixtures.album(50, "In Rainbows"))],"total":2,"nextOffset":200}"#)
        }
        await board.load(.albums, sort: .year, genre: 5)
        XCTAssertEqual(board.albums?.items.map(\.id), [50, 51])
        XCTAssertEqual(board.caption(.albums, playlists: 0), "2 albums")
        XCTAssertEqual(
            transport.queries(.get, "/music/albums"),
            ["genreId=5&sort=year&limit=200", "genreId=5&sort=year&limit=200&offset=200"])
    }

    func testSongsReadOnePageAndCountThemAllFromIt() async {
        transport.routes["GET /music/songs"] = (
            .ok, #"{"items":[\#(Fixtures.song(1, "15 Step"))],"total":201,"nextOffset":200}"#
        )
        await board.load(.songs, sort: .title, genre: nil)
        XCTAssertEqual(board.songs?.items.count, 1)
        XCTAssertEqual(board.caption(.songs, playlists: 0), "201 songs")
        XCTAssertEqual(transport.queries(.get, "/music/songs").count, 1)
    }

    func testCaptionsBeforeAnythingLoadsAndForPlaylists() {
        XCTAssertEqual(board.caption(.artists, playlists: 0), "")
        XCTAssertEqual(board.caption(.playlists, playlists: 3), "3 playlists")
        XCTAssertEqual(board.caption(.playlists, playlists: 1), "1 playlist")
    }

    func testStationsCountOnceRead() {
        XCTAssertEqual(board.caption(.stations, playlists: 2), "")
        XCTAssertEqual(board.caption(.stations, playlists: 2, stations: 1), "1 station")
        XCTAssertEqual(board.caption(.stations, playlists: 2, stations: 6), "6 stations")
    }

    func testAChoiceWithNoGenresLeavesTheMenuEmpty() async {
        await board.loadGenres()
        XCTAssertTrue(board.genres.isEmpty)
    }

    func testARefreshReadsTheTabAgainInPlace() async {
        transport.routes["GET /music/albums"] = (.ok, Fixtures.page([Fixtures.album(50, "In Rainbows")]))
        transport.routes["GET /music/songs"] = (.ok, Fixtures.page([Fixtures.song(1, "15 Step")]))
        await board.load(.albums, sort: .added, genre: nil)
        await board.load(.songs, sort: .added, genre: nil)
        let (albums, songs) = (board.albums, board.songs)
        transport.routes["GET /music/albums"] = (
            .ok, Fixtures.page([Fixtures.album(50, "In Rainbows"), Fixtures.album(51, "Kid A")])
        )
        transport.routes["GET /music/songs"] = (.ok, Fixtures.page([Fixtures.song(2, "Bodysnatchers")]))

        await board.refresh(.albums)
        XCTAssertTrue(board.albums === albums)
        XCTAssertEqual(board.albums?.items.map(\.id), [50, 51])
        XCTAssertEqual(board.songs?.items.map(\.id), [1], "only the tab in view")

        await board.refresh(.songs)
        XCTAssertTrue(board.songs === songs)
        XCTAssertEqual(board.songs?.items.map(\.id), [2])
    }

    func testAKidHasEveryMusicTabButPlaylists() {
        XCTAssertEqual(MusicTab.tabs(playlists: true), MusicTab.allCases)
        XCTAssertEqual(MusicTab.tabs(playlists: false), [.albums, .artists, .songs, .stations])
    }
}
