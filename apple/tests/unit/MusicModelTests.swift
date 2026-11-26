import Foundation
import RabbitEarsAPI
import XCTest

@testable import RabbitEarsKit

extension Fixtures {
    static func album(_ id: Int64, _ title: String, year: Int = 2007, played: String? = nil) -> String {
        let last = played.map { #","lastPlayedAt":"\#($0)""# } ?? ""
        return #"{"id":\#(id),"libraryId":3,"artistId":40,"artistName":"Radiohead","title":"\#(title)","#
            + #""year":\#(year),"songCount":10,"durationMs":2532000,"lossless":true,"genres":[],"#
            + #""addedAt":"2026-01-01T00:00:00Z"\#(last)}"#
    }

    static let artist =
        #"{"id":40,"libraryId":3,"name":"Radiohead","sortName":"Radiohead","albumCount":9,"songCount":112,"#
        + #""genres":[{"id":5,"name":"Alternative rock"}],"addedAt":"2026-01-01T00:00:00Z"}"#
}

@MainActor
final class MusicModelTests: XCTestCase {
    var transport: RoutingTransport!
    var model: MusicModel!

    override func setUp() async throws {
        transport = RoutingTransport()
        model = MusicModel(
            client: ServerEndpoint(userInput: "192.168.1.9")!.client(token: "t", transport: transport),
            profileId: 1)
    }

    func testAlbumHasEverySongPageAndMoreByTheArtistWithoutItself() async throws {
        transport.routes = [
            "GET /music/albums/50": (.ok, Fixtures.album(50, "In Rainbows")),
            "GET /music/albums": (
                .ok, Fixtures.page([Fixtures.album(51, "OK Computer", year: 1997), Fixtures.album(50, "In Rainbows")])
            ),
        ]
        transport.respond = { sent in
            guard sent.path == "/music/songs" else { return nil }
            return sent.query.contains("offset=200")
                ? (.ok, Fixtures.page([Fixtures.song(3, "Nude", track: 3)], total: 2))
                : (.ok, #"{"items":[\#(Fixtures.song(1, "15 Step", track: 1))],"total":2,"nextOffset":200}"#)
        }
        let detail = try await model.album(50)
        XCTAssertEqual(detail.album.title, "In Rainbows")
        XCTAssertEqual(detail.songs.map(\.title), ["15 Step", "Nude"])
        XCTAssertEqual(detail.moreByArtist.map(\.id), [51])
        XCTAssertEqual(detail.discs, [1])
        XCTAssertTrue(transport.queries(.get, "/music/songs").allSatisfy { $0.contains("albumId=50") })
        XCTAssertEqual(transport.queries(.get, "/music/albums"), ["artistId=40&sort=year&limit=21"])
    }

    func testArtistAsksForTheFiveMostPlayedAndEveryAlbumNewestFirst() async throws {
        transport.routes = [
            "GET /music/artists/40": (.ok, Fixtures.artist),
            "GET /music/songs": (.ok, Fixtures.page([Fixtures.song(4, "Weird Fishes / Arpeggi")])),
            "GET /music/albums": (.ok, Fixtures.page([Fixtures.album(50, "In Rainbows")])),
        ]
        let detail = try await model.artist(40)
        XCTAssertEqual(detail.artist.name, "Radiohead")
        XCTAssertEqual(detail.popular.map(\.id), [4])
        XCTAssertEqual(detail.albums.map(\.id), [50])
        XCTAssertEqual(transport.queries(.get, "/music/songs"), ["artistId=40&sort=popular&limit=5"])
        XCTAssertEqual(transport.queries(.get, "/music/albums"), ["artistId=40&sort=year&limit=200"])
    }

    func testHomeIsRecentlyPlayedAndRecentlyAddedAlbums() async throws {
        let recent =
            #"{"kind":"album","playedAt":"2026-05-01T00:00:00Z","album":\#(Fixtures.album(50, "In Rainbows"))}"#
        transport.routes = [
            "GET /profiles/1/music/recently-played": (.ok, Fixtures.page([recent])),
            "GET /music/albums": (.ok, Fixtures.page([Fixtures.album(52, "Kid A")])),
        ]
        let home = try await model.home()
        XCTAssertEqual(home.recentlyPlayed.map(\.album?.id), [50])
        XCTAssertEqual(home.recentlyAdded.map(\.id), [52])
        XCTAssertEqual(transport.queries(.get, "/music/albums"), ["sort=added&limit=20"])
        _ = try await model.recentlyPlayed(kind: .artist, limit: 12)
        XCTAssertEqual(transport.queries(.get, "/profiles/1/music/recently-played").last, "kind=artist&limit=12")
    }

    func testLettersSearchAndListings() async throws {
        transport.routes = [
            "GET /music/letters": (.ok, ##"{"items":[{"letter":"A","count":3},{"letter":"#","count":1}]}"##),
            "GET /music/search": (
                .ok, #"{"artists":[\#(Fixtures.artist)],"albums":[],"songs":[\#(Fixtures.song(4, "Nude"))]}"#
            ),
            "GET /music/artists": (.ok, Fixtures.page([Fixtures.artist])),
        ]
        let letters = try await model.letters(of: .artists)
        XCTAssertEqual(letters.map(\.letter), ["A", "#"])
        XCTAssertEqual(transport.queries(.get, "/music/letters"), ["of=artists"])
        let found = try await model.search(" nude ")
        XCTAssertEqual(found.songs.map(\.id), [4])
        XCTAssertEqual(transport.queries(.get, "/music/search"), ["q=nude&limit=20"])
        let none = try await model.search("  ")
        XCTAssertTrue(none.songs.isEmpty && none.artists.isEmpty)
        XCTAssertEqual(transport.queries(.get, "/music/search").count, 1)
        let page = try await model.artists(letter: "R")
        XCTAssertEqual(page.items.map(\.id), [40])
        XCTAssertEqual(transport.queries(.get, "/music/artists"), ["letter=R&limit=100"])
    }

    func testAnUnknownAlbumThrowsTheServersWords() async {
        transport.routes = ["GET /music/albums/9": (.notFound, Fixtures.error("not_found", "No such album."))]
        do {
            _ = try await model.album(9)
            XCTFail("expected a throw")
        } catch {
            XCTAssertEqual(error as? AppError, .server("No such album."))
        }
    }

    func testCodecNamesAndSongCounts() {
        XCTAssertEqual(Format.codec("pcm_s16le"), "PCM")
        XCTAssertEqual(Format.songs(10, durationMs: 2_532_000), "10 songs · 42m")
        XCTAssertEqual(Format.songs(1, durationMs: 200_000), "1 song · 3m")
    }

    func testSortMenusNameEachOrder() {
        XCTAssertEqual(MusicAlbumSort.added.title, "Recently added")
        XCTAssertEqual(MusicSongSort.popular.title, "Popular")
        XCTAssertEqual(YouTubeVideoSort.played.title, "Recently played")
    }
}
