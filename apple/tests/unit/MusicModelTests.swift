import Foundation
import GRDB
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
    var fixture: ReplicaFixture!

    override func setUp() async throws {
        transport = RoutingTransport()
        fixture = ReplicaFixture()
    }

    override func tearDown() async throws { fixture.remove() }

    /// Avery an adult (1) and Kit a kid (3). Radiohead (40) has In Rainbows
    /// (50, 2007), OK Computer (51, 1997) and Undated (54); The Beatles (41,
    /// filed as Beatles) have Abbey Road (52, 1969) and Rude (53), which
    /// holds only an explicit song; Guest (42) performs a song on In Rainbows.
    private func library(_ rows: @escaping (Database) throws -> Void = { _ in }) throws -> Replica {
        try fixture.v1 { db in
            try db.account(1, "Avery")
            try db.account(3, "Kit", kind: "kid", movies: "PG", tv: "TV-Y")
            try db.library(3, "music")
            try db.artist(40, "Radiohead")
            try db.artist(41, "The Beatles", sort: "Beatles")
            try db.artist(42, "Guest")
            try db.album(50, "In Rainbows", artist: 40, year: 2007, added: "2026-02-01T00:00:00Z")
            try db.album(51, "OK Computer", artist: 40, year: 1997, added: "2026-03-01T00:00:00Z")
            try db.album(54, "Undated", artist: 40, added: "2026-01-15T00:00:00Z")
            try db.album(52, "Abbey Road", artist: 41, year: 1969, added: "2026-01-10T00:00:00Z")
            try db.album(53, "Rude", artist: 41, year: 2001, added: "2026-04-01T00:00:00Z")
            try db.song(3, "Nude", album: 50, track: 3, durationMs: 255_000)
            try db.song(1, "15 Step", album: 50, track: 1, durationMs: 237_000, codec: "pcm_s16le")
            try db.song(2, "Weird Fishes", album: 50, disc: 2, track: 1, performer: 42, explicit: true, codec: "mp3")
            try db.song(4, "Airbag", album: 51, track: 1, year: 1996, missing: true)
            try db.song(5, "Come Together", album: 52, track: 1)
            try db.song(6, "Swear", album: 53, track: 1, explicit: true)
            try db.song(7, "Undated Song", album: 54, codec: nil)
            try db.described(50, overview: "Seventh album.", mbid: "mb-50")
            try db.described(51, overview: "Third album.", mbid: "mb-51", status: "unmatched")
            try db.genre(6, "Rock", on: 50)
            try db.genre(5, "Alternative", on: 50)
            try db.genre(5, "Alternative", on: 41)
            try rows(db)
        }
    }

    private func model(_ replica: Replica, _ profile: Int64 = 1) -> MusicModel {
        MusicModel(
            client: ServerEndpoint(userInput: "192.168.1.9")!.client(token: "t", transport: transport),
            replica: replica, profileId: profile)
    }

    func testAlbumHasItsSongsByDiscThenTrackAndMoreByTheArtistNewestFirst() async throws {
        let detail = try await model(library()).album(50)
        XCTAssertEqual(
            detail.album,
            MusicAlbum(
                id: 50, libraryId: 3, artistId: 40, artistName: "Radiohead", title: "In Rainbows", year: 2007,
                songCount: 3, durationMs: 692_000, lossless: false, overview: "Seventh album.",
                genres: [Genre(id: 5, name: "Alternative"), Genre(id: 6, name: "Rock")], musicBrainzId: "mb-50",
                addedAt: Fixtures.decode(#""2026-02-01T00:00:00Z""#)))
        XCTAssertEqual(detail.songs.map(\.id), [1, 3, 2])
        XCTAssertEqual(detail.discs, [1, 2])
        XCTAssertEqual(
            detail.songs[2],
            MusicSong(
                id: 2, libraryId: 3, albumId: 50, albumTitle: "In Rainbows", albumArtistId: 40, artistId: 42,
                artistName: "Guest", title: "Weird Fishes", discNumber: 2, trackNumber: 1, durationMs: 200_000,
                year: 2007, codec: "mp3", lossless: false))
        XCTAssertEqual(detail.songs[0].codec, "pcm_s16le")
        XCTAssertTrue(detail.songs[0].lossless)
        XCTAssertEqual(detail.moreByArtist.map(\.id), [51, 54], "by year, the undated last, without itself")
        XCTAssertTrue(transport.sent.isEmpty, "read from the replica")
    }

    func testAKidHearsNoExplicitSongAndCountsOnlyTheOthers() async throws {
        let kid = model(try library(), 3)
        let album = try await kid.album(50)
        XCTAssertEqual(album.songs.map(\.id), [1, 3])
        XCTAssertEqual(album.album.songCount, 2)
        XCTAssertEqual(album.album.durationMs, 492_000)
        do {
            _ = try await kid.album(53)
            XCTFail("an album of only explicit songs is not found")
        } catch {
            XCTAssertEqual(error as? AppError, .server("not found"))
        }
        let albums = try await kid.albums(sort: .added)
        XCTAssertEqual(albums.items.map(\.id), [51, 50, 54, 52])
        XCTAssertEqual(albums.total, 4)
        let artists = try await kid.artists().items
        XCTAssertEqual(artists.map(\.id), [41, 40], "Guest performs only an explicit song")
        XCTAssertEqual(artists.map(\.songCount), [1, 4])
    }

    func testArtistCountsItsAlbumsAndSongsWithPopularFromTheServerAndAlbumsNewestFirst() async throws {
        transport.routes["GET /music/songs"] = (.ok, Fixtures.page([Fixtures.song(3, "Nude")]))
        let detail = try await model(library()).artist(40)
        XCTAssertEqual(detail.artist.name, "Radiohead")
        XCTAssertEqual(detail.artist.sortName, "Radiohead")
        XCTAssertEqual(detail.artist.albumCount, 3)
        XCTAssertEqual(detail.artist.songCount, 5)
        XCTAssertEqual(detail.popular.map(\.id), [3])
        XCTAssertEqual(transport.queries(.get, "/music/songs"), ["artistId=40&sort=popular&limit=5"])
        XCTAssertEqual(detail.albums.map(\.id), [50, 51, 54])
        let guest = try await model(library()).artist(42)
        XCTAssertEqual([guest.artist.albumCount, guest.artist.songCount], [0, 1], "a performer on another's album")
        let beatles = try await model(library()).artist(41)
        XCTAssertEqual(beatles.artist.sortName, "Beatles")
        XCTAssertEqual(beatles.artist.genres.map(\.name), ["Alternative"])
    }

    func testAlbumsSortPageAndFilterAsTheServerDoes() async throws {
        let music = model(try library())
        let byTitle = try await music.albums(sort: .title)
        XCTAssertEqual(byTitle.items.map(\.id), [52, 50, 51, 53, 54])
        let byArtist = try await music.albums(sort: .artist)
        XCTAssertEqual(byArtist.items.map(\.id), [52, 53, 54, 51, 50], "Beatles first, years rising")
        let byYear = try await music.albums(sort: .year)
        XCTAssertEqual(byYear.items.map(\.id), [50, 53, 51, 52, 54])
        let byAdded = try await music.albums(sort: .added)
        XCTAssertEqual(byAdded.items.map(\.id), [53, 51, 50, 54, 52])
        let first = try await music.albums(limit: 2)
        XCTAssertEqual(first.items.map(\.id), [52, 50])
        XCTAssertEqual([first.total, first.nextOffset], [5, 2])
        let last = try await music.albums(offset: 4, limit: 2)
        XCTAssertEqual(last.items.map(\.id), [54])
        XCTAssertNil(last.nextOffset)
        let alternative = try await music.albums(genreId: 5)
        XCTAssertEqual(alternative.items.map(\.id), [50])
        let underO = try await music.albums(letter: "O")
        XCTAssertEqual(underO.items.map(\.id), [51])
    }

    func testSongsSortByTitleAndAnArtistsSongsGoAlbumByAlbum() async throws {
        let music = model(try library())
        let songs = try await music.songs()
        XCTAssertEqual(songs.items.map(\.id), [1, 4, 5, 3, 6, 7, 2])
        XCTAssertEqual(songs.items[1].unavailable, true)
        XCTAssertEqual(songs.items[1].year, 1996)
        XCTAssertNil(songs.items[5].durationMs)
        let added = try await music.songs(sort: .added, limit: 1)
        XCTAssertEqual(added.total, 7)
        let rock = try await music.songs(genreId: 6)
        XCTAssertEqual(rock.items.map(\.id), [1, 3, 2], "by their album's genre")
        let radiohead = try await music.songs(byArtist: 40)
        XCTAssertEqual(radiohead.map(\.id), [1, 3, 2, 4, 7])
        let guest = try await music.songs(byArtist: 42)
        XCTAssertEqual(guest.map(\.id), [2])
    }

    func testHomeIsRecentlyPlayedFromTheServerAndRecentlyAddedAlbums() async throws {
        let recent =
            #"{"kind":"album","playedAt":"2026-05-01T00:00:00Z","album":\#(Fixtures.album(50, "In Rainbows"))}"#
        transport.routes["GET /profiles/1/music/recently-played"] = (.ok, Fixtures.page([recent]))
        let home = try await model(library()).home(limit: 2)
        XCTAssertEqual(home.recentlyPlayed.map(\.album?.id), [50])
        XCTAssertEqual(home.recentlyAdded.map(\.id), [53, 51])
        _ = try await model(library()).recentlyPlayed(kind: .artist, limit: 12)
        XCTAssertEqual(transport.queries(.get, "/profiles/1/music/recently-played").last, "kind=artist&limit=12")
    }

    func testLettersFileUnderTheSortNameAToZThenHash() async throws {
        let replica = try library { db in
            try db.artist(43, "4 Non Blondes")
            try db.artist(44, "abba")
        }
        let artists = try await model(replica).letters(of: .artists)
        XCTAssertEqual(artists.map(\.letter), ["A", "B", "G", "R", "#"])
        XCTAssertEqual(artists.map(\.count), [1, 1, 1, 1, 1])
        let kids = try await model(replica, 3).letters(of: .albums)
        XCTAssertEqual(kids.map(\.letter), ["A", "I", "O", "U"], "Rude holds only an explicit song")
    }

    func testSearchFindsPrefixMatchesFirst() async throws {
        let replica = try library { db in try db.album(55, "Rainbow Road", artist: 41, year: 2020) }
        let found = try await model(replica).search(" rainbow ")
        XCTAssertEqual(found.albums.map(\.id), [55, 50])
        XCTAssertEqual(found.artists, [])
        let songs = try await model(replica).search("e", limit: 2)
        XCTAssertEqual(songs.songs.map(\.id), [1, 5], "none starts with e; by title, to the limit")
        let none = try await model(replica).search("  ")
        XCTAssertTrue(none.songs.isEmpty && none.artists.isEmpty)
        XCTAssertTrue(transport.sent.isEmpty)
    }

    func testAnUnknownAlbumOrArtistIsNotFound() async throws {
        let music = model(try library())
        for read in [{ _ = try await music.album(9) }, { _ = try await music.artist(50) }] {
            do {
                try await read()
                XCTFail("expected a throw")
            } catch {
                XCTAssertEqual(error as? AppError, .server("not found"))
            }
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
