import Foundation
import RabbitEarsAPI
import XCTest

@testable import RabbitEarsKit

/// Every list holds no more rows or sections than the car allows, while
/// Play still queues everything.
@MainActor
final class CarPlayLimitsTests: XCTestCase {
    var transport: RoutingTransport!
    var library: CarPlayLibrary!

    override func setUp() async throws {
        transport = RoutingTransport()
        let client = ServerEndpoint(userInput: "192.168.1.9")!.client(token: "t", transport: transport)
        library = CarPlayLibrary(music: MusicModel(client: client, profileId: 1))
    }

    private func limits(items: Int, sections: Int = 50) -> CarPlayLimits {
        CarPlayLimits(maxItems: items, maxSections: sections, limited: false)
    }

    func testRecentStopsAtTheCarsRowsAndSections() async throws {
        transport.routes = [
            "GET /profiles/1/music/recently-played": (
                .ok,
                Fixtures.page([
                    Fixtures.recent("album", Fixtures.album(50, "In Rainbows")),
                    Fixtures.recent("album", Fixtures.album(51, "Kid A")),
                ])
            ),
            "GET /music/albums": (.ok, Fixtures.page([Fixtures.album(60, "Punisher")])),
        ]
        let rows = try await library.recent(limits(items: 3))
        XCTAssertEqual(rows.sections.map { $0.rows.map(\.text) }, [["In Rainbows", "Kid A"], ["Punisher"]])
        let few = try await library.recent(limits(items: 2))
        XCTAssertEqual(few.sections.map(\.header), ["Recently played"], "a section with no room left is left off")
        let one = try await library.recent(limits(items: 50, sections: 1))
        XCTAssertEqual(one.sections.map(\.header), ["Recently played"])
    }

    func testPlaylistsStopAtTheCarsRows() async throws {
        transport.routes = [
            "GET /profiles/1/playlists": (
                .ok,
                Fixtures.page([Fixtures.playlist(3, "Road trip", count: 48), Fixtures.playlist(4, "Focus", count: 9)])
            ),
            "GET /stations": (.ok, Fixtures.page([])),
        ]
        let list = try await library.playlists(limits(items: 1))
        XCTAssertEqual(list.sections.flatMap(\.rows).map(\.text), ["Road trip"])
    }

    func testAnArtistStopsAtTheCarsRows() async throws {
        transport.routes = [
            "GET /music/artists/40": (.ok, Fixtures.artist),
            "GET /music/songs": (.ok, Fixtures.page([])),
            "GET /music/albums": (
                .ok, Fixtures.page([Fixtures.album(50, "In Rainbows"), Fixtures.album(51, "Kid A")])
            ),
        ]
        let list = try await library.artist(40, limits(items: 1))
        XCTAssertEqual(list.sections.flatMap(\.rows).map(\.text), ["In Rainbows"])
        XCTAssertEqual(list.header?.play, .artist(40, name: "Radiohead"))
    }

    func testAnAlbumShowsWhatFitsAndPlaysEverySong() async throws {
        transport.routes = [
            "GET /music/albums/50": (.ok, Fixtures.album(50, "In Rainbows")),
            "GET /music/albums": (.ok, Fixtures.page([])),
            "GET /music/songs": (.ok, Fixtures.page((1...3).map { Fixtures.song(Int64($0), "S\($0)", track: $0) })),
        ]
        let list = try await library.album(50, limits(items: 2))
        XCTAssertEqual(list.sections.flatMap(\.rows).map(\.text), ["S1", "S2"])
        XCTAssertEqual(list.queue?.songs.map(\.id), [1, 2, 3])
    }

    func testAPlaylistShowsWhatFitsAndPlaysEverySong() async throws {
        transport.routes = [
            "GET /profiles/1/playlists/3": (.ok, Fixtures.playlist(3, "Road trip", count: 3)),
            "GET /profiles/1/playlists/3/play-order": (
                .ok,
                Fixtures.page([
                    Fixtures.row(entry: 1, song: 9), Fixtures.row(entry: 2, song: 10), Fixtures.row(entry: 3, song: 11),
                ])
            ),
        ]
        let list = try await library.playlist(3, limits(items: 1))
        XCTAssertEqual(list.sections.flatMap(\.rows).count, 1)
        XCTAssertEqual(list.queue?.songs.map(\.id), [9, 10, 11])
    }
}
