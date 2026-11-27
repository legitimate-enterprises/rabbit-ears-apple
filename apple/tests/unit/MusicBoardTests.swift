import Foundation
import GRDB
import RabbitEarsAPI
import XCTest

@testable import RabbitEarsKit

@MainActor
final class MusicBoardTests: XCTestCase {
    var fixture: ReplicaFixture!
    var replica: Replica!
    var board: MusicBoard!

    /// 201 albums of one artist, each with one song (its id plus 1000): one more than a page.
    override func setUp() async throws {
        fixture = ReplicaFixture()
        replica = try fixture.v1 { db in
            try db.account(1, "Avery")
            try db.library(3, "music")
            try db.artist(40, "Radiohead")
            for number in 100...300 {
                try db.album(.n(number), "Album \(number)", artist: 40, year: number)
                try db.song(.n(number + 1000), "Song \(number)", album: .n(number))
            }
            try db.genre(5, "Jazz", on: 100)
            try db.genre(5, "Jazz", on: 101)
        }
        board = MusicBoard(
            music: MusicModel(
                client: ServerEndpoint(userInput: "192.168.1.9")!.client(token: "t", transport: RoutingTransport()),
                replica: replica, profileId: 1))
    }

    override func tearDown() async throws { fixture.remove() }

    func testAlbumsReadEveryPageWithTheChosenSortAndGenre() async {
        await board.load(.albums, sort: .year, genre: nil)
        XCTAssertEqual(board.albums?.items.count, 201)
        XCTAssertEqual(board.albums?.items.first?.id, 300, "newest year first")
        XCTAssertEqual(board.caption(.albums, playlists: 0), "201 albums")
        await board.load(.albums, sort: .year, genre: 5)
        XCTAssertEqual(board.albums?.items.map(\.id), [101, 100])
    }

    func testSongsReadOnePageAndCountThemAllFromIt() async {
        await board.load(.songs, sort: .title, genre: nil)
        XCTAssertEqual(board.songs?.items.count, 200)
        XCTAssertEqual(board.caption(.songs, playlists: 0), "201 songs")
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

    func testTheGenreMenuIsTheLibrarysGenres() async {
        await board.loadGenres()
        XCTAssertEqual(board.genres.map(\.name), ["Jazz"])
    }

    func testARefreshReadsTheTabAgainInPlace() async throws {
        await board.load(.albums, sort: .added, genre: 5)
        await board.load(.songs, sort: .added, genre: 5)
        let (albums, songs) = (board.albums, board.songs)
        try await replica.write { db in
            try db.genre(5, "Jazz", on: 102)
            try db.execute(sql: "DELETE FROM item_genre WHERE item_id = \(sqlID(100))")
        }

        await board.refresh(.albums)
        XCTAssertTrue(board.albums === albums)
        XCTAssertEqual(board.albums?.items.map(\.id), [102, 101])
        XCTAssertEqual(board.songs?.items.map(\.id), [1100, 1101], "only the tab in view")

        await board.refresh(.songs)
        XCTAssertTrue(board.songs === songs)
        XCTAssertEqual(board.songs?.items.map(\.id), [1101, 1102])
    }

    func testAKidHasEveryMusicTabButPlaylists() {
        XCTAssertEqual(MusicTab.tabs(playlists: true), MusicTab.allCases)
        XCTAssertEqual(MusicTab.tabs(playlists: false), [.albums, .artists, .songs, .stations])
    }
}
