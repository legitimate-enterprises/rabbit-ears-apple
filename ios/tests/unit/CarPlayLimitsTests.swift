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
        library = try carPlay(transport)
    }

    private func limits(items: Int, sections: Int = 50) -> CarPlayLimits {
        CarPlayLimits(maxItems: items, maxSections: sections, limited: false)
    }

    func testRecentStopsAtTheCarsRowsAndSections() async throws {
        transport.routes = [
            "GET /profiles/\(UID.n(1))/music/recently-played": (
                .ok,
                Fixtures.page([
                    Fixtures.recent("album", Fixtures.album(50, "In Rainbows")),
                    Fixtures.recent("album", Fixtures.album(51, "Kid A")),
                ])
            )
        ]
        library = try carPlay(transport) { db in try db.album(60, "Punisher", artist: 40) }
        let rows = try await library.recent(limits(items: 3))
        XCTAssertEqual(rows.sections.map { $0.rows.map(\.text) }, [["In Rainbows", "Kid A"], ["Punisher"]])
        let few = try await library.recent(limits(items: 2))
        XCTAssertEqual(few.sections.map(\.header), ["Recently played"], "a section with no room left is left off")
        let one = try await library.recent(limits(items: 50, sections: 1))
        XCTAssertEqual(one.sections.map(\.header), ["Recently played"])
    }

    func testPlaylistsStopAtTheCarsRows() async throws {
        library = try carPlay(transport) { db in
            try db.playlist(3, "Road trip", kind: "music")
            try db.playlist(4, "Focus", kind: "music")
        }
        let list = try await library.playlists(limits(items: 1))
        XCTAssertEqual(list.sections.flatMap(\.rows).map(\.text), ["Focus"], "by name")
    }

    func testAnArtistStopsAtTheCarsRows() async throws {
        transport.routes["GET /music/songs"] = (.ok, Fixtures.page([]))
        library = try carPlay(transport) { db in
            try db.album(50, "In Rainbows", artist: 40, year: 2007)
            try db.album(51, "Kid A", artist: 40, year: 2000)
        }
        let list = try await library.artist(40, limits(items: 1))
        XCTAssertEqual(list.sections.flatMap(\.rows).map(\.text), ["In Rainbows"])
        XCTAssertEqual(list.header?.play, .artist(40, name: "Radiohead"))
    }

    func testAnAlbumShowsWhatFitsAndPlaysEverySong() async throws {
        library = try carPlay(transport) { db in
            try db.album(50, "In Rainbows", artist: 40)
            for track in 1...3 { try db.song(.n(track), "S\(track)", album: 50, track: track) }
        }
        let list = try await library.album(50, limits(items: 2))
        XCTAssertEqual(list.sections.flatMap(\.rows).map(\.text), ["S1", "S2"])
        XCTAssertEqual(list.queue?.songs.map(\.id), [1, 2, 3])
    }

    func testAPlaylistShowsWhatFitsAndPlaysEverySong() async throws {
        library = try carPlay(transport) { db in
            try db.album(50, "In Rainbows", artist: 40)
            try db.playlist(3, "Road trip", kind: "music")
            for (entry, song) in [(1, 9), (2, 10), (3, 11)] {
                try db.song(.n(song), "S\(song)", album: 50, track: entry)
                try db.entry(.n(entry), in: 3, item: .n(song), rank: "a\(entry)")
            }
        }
        let list = try await library.playlist(3, limits(items: 1))
        XCTAssertEqual(list.sections.flatMap(\.rows).count, 1)
        XCTAssertEqual(list.queue?.songs.map(\.id), [9, 10, 11])
    }
}
