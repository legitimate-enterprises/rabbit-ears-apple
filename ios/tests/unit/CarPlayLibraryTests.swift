import Foundation
import RabbitEarsAPI
import XCTest

@testable import RabbitEarsKit

extension Fixtures {
    static func recent(_ kind: String, _ json: String) -> String {
        #"{"kind":"\#(kind)","playedAt":"2026-01-01T00:00:00Z","\#(kind)":\#(json)}"#
    }

    static func letters(_ counts: [(String, Int)]) -> String {
        Fixtures.page(counts.map { #"{"letter":"\#($0.0)","count":\#($0.1)}"# })
    }
}

@MainActor
final class CarPlayLibraryTests: XCTestCase {
    var transport: RoutingTransport!
    var library: CarPlayLibrary!
    let roomy = CarPlayLimits(maxItems: 500, maxSections: 50, limited: false)

    override func setUp() async throws {
        transport = RoutingTransport()
        let client = ServerEndpoint(userInput: "192.168.1.9")!.client(token: "t", transport: transport)
        library = CarPlayLibrary(music: MusicModel(client: client, profileId: 1))
    }

    private func account(_ json: String) -> Account { Fixtures.decode(json) }

    func testGateNamesEveryStateWithNoMusic() {
        let adult = account(Fixtures.adult)
        XCTAssertEqual(
            CarPlayGate(phase: .signedOut, profile: nil, online: false, reachable: true).message,
            CarPlayMessage("Not signed in", "Music appears here once Rabbit Ears is signed in."))
        XCTAssertEqual(CarPlayGate(phase: .browsing, profile: adult, online: false, reachable: true), .offline)
        XCTAssertEqual(CarPlayGate.offline.message?.title, "No connection")
        XCTAssertEqual(
            CarPlayGate(phase: .unreachable, profile: nil, online: true, reachable: true).message,
            CarPlayMessage("Can\u{2019}t reach your server", "Rabbit Ears keeps trying and reconnects on its own."))
        XCTAssertEqual(CarPlayGate(phase: .browsing, profile: adult, online: true, reachable: false), .unreachable)
        XCTAssertEqual(
            CarPlayGate(phase: .browsing, profile: account(Fixtures.kid), online: true, reachable: true), .music(2),
            "a kid browses the music the server allows them")
        let choosing = CarPlayMessage(
            "Choose who\u{2019}s watching on your iPhone", "Music appears here once a profile is picked.")
        XCTAssertEqual(
            CarPlayGate(phase: .choosingProfile, profile: adult, online: true, reachable: true).message, choosing,
            "signed in, with no one picked yet")
        XCTAssertEqual(
            CarPlayGate(phase: .choosingHousehold, profile: adult, online: true, reachable: true).message, choosing)
        XCTAssertEqual(
            CarPlayGate(phase: .choosingProfile, profile: adult, online: false, reachable: true), .choosingProfile)
        XCTAssertEqual(CarPlayGate(phase: .browsing, profile: adult, online: true, reachable: true), .music(1))
        XCTAssertEqual(CarPlayGate(phase: .starting, profile: nil, online: true, reachable: true), .loading)
        XCTAssertNil(CarPlayGate.loading.message)
    }

    func testLettersIgnoreALeadingTheAndAccentsAndFileTheRestUnderHash() {
        XCTAssertEqual(CarPlayLibrary.letter("The Beatles"), "B")
        XCTAssertEqual(CarPlayLibrary.letter("\u{C9}dith Piaf"), "E")
        XCTAssertEqual(CarPlayLibrary.letter("4 Non Blondes"), "#")
        XCTAssertEqual(CarPlayLibrary.letter("Theory"), "T")
    }

    func testAlbumsThatFitAreOneListAToZWithIndexLetters() async throws {
        transport.routes = [
            "GET /music/letters": (.ok, Fixtures.letters([("A", 1), ("B", 2), ("#", 1)])),
            "GET /music/albums": (
                .ok,
                Fixtures.page([
                    Fixtures.album(1, "1999"), Fixtures.album(2, "Abbey Road"), Fixtures.album(3, "Blue"),
                    Fixtures.album(4, "The Blue Train"),
                ])
            ),
        ]
        let list = try await library.albums(roomy)
        XCTAssertEqual(list.sections.map(\.index), ["A", "B", "#"])
        XCTAssertEqual(list.sections.map(\.header), ["A", "B", "#"])
        XCTAssertEqual(list.sections[1].rows.map(\.text), ["Blue", "The Blue Train"])
        let row = list.sections[0].rows[0]
        XCTAssertEqual(row.detail, "Radiohead")
        XCTAssertEqual(row.art, .square(2))
        XCTAssertTrue(row.opens)
        XCTAssertEqual(row.action, .open(.album(2)))
        XCTAssertEqual(transport.queries(.get, "/music/letters"), ["of=albums"])
        XCTAssertEqual(transport.queries(.get, "/music/albums"), ["sort=title&limit=200"])
    }

    func testAlbumsThatDoNotFitAreLetterRowsWithCounts() async throws {
        transport.routes["GET /music/letters"] = (.ok, Fixtures.letters([("A", 96), ("B", 1)]))
        let list = try await library.albums(CarPlayLimits(maxItems: 50, maxSections: 50, limited: false))
        let rows = list.sections.flatMap(\.rows)
        XCTAssertEqual(rows.map(\.text), ["A", "B"])
        XCTAssertEqual(rows.map(\.detail), ["96 albums", "1 album"])
        XCTAssertEqual(rows[0].action, .open(.letter(.albums, "A")))
        XCTAssertTrue(rows[0].opens)
        XCTAssertNil(rows[0].art)
        XCTAssertTrue(transport.paths(.get).allSatisfy { $0 == "/music/letters" })
    }

    func testMoreLettersThanSectionsAlsoBecomeLetterRows() async throws {
        transport.routes["GET /music/letters"] = (.ok, Fixtures.letters([("A", 1), ("B", 1), ("C", 1)]))
        let list = try await library.artists(CarPlayLimits(maxItems: 50, maxSections: 2, limited: false))
        XCTAssertEqual(list.sections.flatMap(\.rows).map(\.detail), ["1 artist", "1 artist", "1 artist"])
    }

    func testALimitedCarShowsTheTwelveMostRecentlyPlayed() async throws {
        transport.routes["GET /profiles/1/music/recently-played"] = (
            .ok, Fixtures.page([Fixtures.recent("artist", Fixtures.artist)])
        )
        let list = try await library.artists(CarPlayLimits(maxItems: 12, maxSections: 50, limited: true))
        let row = try XCTUnwrap(list.sections.first?.rows.first)
        XCTAssertEqual(row.text, "Radiohead")
        XCTAssertEqual(row.art, .round(40))
        XCTAssertEqual(row.action, .open(.artist(40)))
        XCTAssertEqual(transport.queries(.get, "/profiles/1/music/recently-played"), ["kind=artist&limit=12"])
    }

    func testALetterListsItsAlbumsCutToTheCarsLimit() async throws {
        transport.routes["GET /music/albums"] = (
            .ok, Fixtures.page([Fixtures.album(1, "Blue"), Fixtures.album(2, "Blue Train")])
        )
        let list = try await library.letter(.albums, "B", CarPlayLimits(maxItems: 1, maxSections: 50, limited: false))
        XCTAssertEqual(list.title, "B")
        XCTAssertEqual(list.sections.flatMap(\.rows).map(\.text), ["Blue"])
        XCTAssertEqual(transport.queries(.get, "/music/albums"), ["letter=B&sort=title&limit=200"])
    }

    func testRecentPlaysOnTapUnderTwoHeadings() async throws {
        transport.routes = [
            "GET /profiles/1/music/recently-played": (
                .ok,
                Fixtures.page([
                    Fixtures.recent("album", Fixtures.album(50, "In Rainbows")),
                    Fixtures.recent("playlist", Fixtures.playlist(3, "Road trip", count: 48)),
                ])
            ),
            "GET /music/albums": (.ok, Fixtures.page([Fixtures.album(60, "Punisher")])),
        ]
        let list = try await library.recent(roomy)
        XCTAssertEqual(list.sections.map(\.header), ["Recently played", "Recently added"])
        let played = list.sections[0].rows
        XCTAssertEqual(played.map(\.detail), ["Radiohead", "Playlist \u{B7} 48 songs"])
        XCTAssertEqual(played.map(\.action), [.play(.album(50)), .play(.playlist(3))])
        XCTAssertFalse(played.contains { $0.opens })
        XCTAssertEqual(list.sections[1].rows.first?.action, .play(.album(60)))
    }

    func testAnEmptyLibrarySaysNoMusicYet() async throws {
        transport.routes = [
            "GET /profiles/1/music/recently-played": (.ok, Fixtures.page([])),
            "GET /music/albums": (.ok, Fixtures.page([])),
            "GET /music/letters": (.ok, Fixtures.page([])),
            "GET /profiles/1/playlists": (.ok, Fixtures.page([])),
            "GET /stations": (.ok, Fixtures.page([])),
        ]
        let noMusic = CarPlayMessage("No music yet", "Albums appear here after your server\u{2019}s next scan.")
        let recent = try await library.recent(roomy)
        XCTAssertTrue(recent.sections.isEmpty)
        XCTAssertEqual(recent.empty, noMusic)
        let albums = try await library.albums(roomy)
        XCTAssertEqual(albums.empty, noMusic)
        let artists = try await library.artists(roomy)
        XCTAssertEqual(artists.empty, noMusic)
        let playlists = try await library.playlists(roomy)
        XCTAssertEqual(playlists.empty, noMusic)
    }

    func testPlaylistsListsOnlyMusicPlaylistsWithSongCounts() async throws {
        transport.routes["GET /profiles/1/playlists"] = (
            .ok,
            Fixtures.page([
                Fixtures.playlist(3, "Road trip", count: 48), Fixtures.playlist(4, "Movie night", kind: "movies"),
            ])
        )
        transport.routes["GET /stations"] = (.ok, Fixtures.page([]))
        let list = try await library.playlists(roomy)
        let rows = list.sections.flatMap(\.rows)
        XCTAssertEqual(rows.map(\.text), ["Road trip"])
        XCTAssertEqual(rows.first?.detail, "48 songs")
        XCTAssertEqual(rows.first?.action, .open(.playlist(3)))
        XCTAssertNil(list.empty)
        XCTAssertEqual(transport.queries(.get, "/profiles/1/playlists"), ["kind=music&limit=200"])
    }

    func testNoPlaylistsInALibraryWithMusicSaysSo() async throws {
        transport.routes = [
            "GET /profiles/1/playlists": (.ok, Fixtures.page([])),
            "GET /music/letters": (.ok, Fixtures.letters([("A", 1)])),
            "GET /stations": (.ok, Fixtures.page([])),
        ]
        let list = try await library.playlists(roomy)
        XCTAssertEqual(list.empty, CarPlayMessage("No playlists"))
    }

    func testMusicStationsSitAbovePlaylistsAndTuneIn() async throws {
        let kitchen = Fixtures.station(
            8, "Kitchen Radio", kind: "music",
            onAir: Fixtures.onAir("on_air", now: Fixtures.program(30, "Paper Lanterns", kind: "song")))
        let sunday = Fixtures.station(
            9, "Sunday Vinyl", kind: "music",
            onAir: Fixtures.onAir("off_schedule", next: Fixtures.program(31, "Blue Hour", kind: "song")))
        transport.routes = [
            "GET /profiles/1/playlists": (.ok, Fixtures.page([Fixtures.playlist(3, "Road trip", count: 48)])),
            "GET /stations": (.ok, Fixtures.page([kitchen, sunday])),
        ]
        let list = try await library.playlists(roomy)
        XCTAssertEqual(list.sections.map(\.header), ["Stations", "Playlists"])
        let stations = list.sections.first?.rows ?? []
        XCTAssertEqual(stations.map(\.text), ["Kitchen Radio"], "a station not playing is not offered")
        let row = try XCTUnwrap(stations.first)
        XCTAssertEqual(row.detail, "On now: Paper Lanterns \u{B7} Radiohead")
        XCTAssertEqual(row.art, .square(50))
        XCTAssertEqual(row.action, .tune(Fixtures.decode(kitchen)))
        XCTAssertFalse(row.opens)
        XCTAssertEqual(list.sections.last?.rows.map(\.text), ["Road trip"])
        XCTAssertEqual(transport.queries(.get, "/stations"), ["kind=music&limit=200"])
    }

    func testNoStationOnAirLeavesOnlyPlaylists() async throws {
        let sunday = Fixtures.station(
            9, "Sunday Vinyl", kind: "music",
            onAir: Fixtures.onAir("between_programs", next: Fixtures.program(31, "Blue Hour", kind: "song")))
        transport.routes = [
            "GET /profiles/1/playlists": (.ok, Fixtures.page([Fixtures.playlist(3, "Road trip", count: 48)])),
            "GET /stations": (.ok, Fixtures.page([sunday])),
        ]
        let list = try await library.playlists(roomy)
        XCTAssertEqual(list.sections.map(\.header), [nil])
        XCTAssertEqual(list.sections.flatMap(\.rows).map(\.text), ["Road trip"])
    }

    func testAStationOffersNoShuffleOrRepeat() {
        XCTAssertEqual(CarPlayLibrary.nowPlayingButtons(station: false), [.shuffle, .repeatMode])
        XCTAssertEqual(CarPlayLibrary.nowPlayingButtons(station: true), [])
    }

    func testStationsWithNoPlaylistsShowAlone() async throws {
        let onAir = Fixtures.onAir("on_air", now: Fixtures.program(30, "Paper Lanterns", kind: "song"))
        let kitchen = Fixtures.station(8, "Kitchen Radio", kind: "music", onAir: onAir)
        transport.routes = [
            "GET /profiles/1/playlists": (.ok, Fixtures.page([])),
            "GET /stations": (.ok, Fixtures.page([kitchen])),
        ]
        let list = try await library.playlists(roomy)
        XCTAssertEqual(list.sections.map(\.header), ["Stations"])
        XCTAssertNil(list.empty)
    }

    func testArtistHasADetailsHeaderAndListsAlbumsOnly() async throws {
        transport.routes = [
            "GET /music/artists/40": (.ok, Fixtures.artist),
            "GET /music/songs": (.ok, Fixtures.page([Fixtures.song(4, "Weird Fishes / Arpeggi")])),
            "GET /music/albums": (.ok, Fixtures.page([Fixtures.album(50, "In Rainbows")])),
        ]
        let list = try await library.artist(40, roomy)
        XCTAssertEqual(list.title, "Artist")
        XCTAssertEqual(
            list.header,
            CarPlayHeader(
                art: .round(40), title: "Radiohead", subtitle: "9 albums \u{B7} 112 songs",
                play: .artist(40, name: "Radiohead")))
        let rows = list.sections.flatMap(\.rows)
        XCTAssertEqual(rows.map(\.text), ["In Rainbows"])
        XCTAssertEqual(rows.first?.detail, "2007")
        XCTAssertEqual(rows.first?.marker, .album(50))
    }

    func testAlbumListsTracksByTitleInAlbumOrder() async throws {
        transport.routes = [
            "GET /music/albums/50": (.ok, Fixtures.album(50, "In Rainbows")),
            "GET /music/albums": (.ok, Fixtures.page([])),
            "GET /music/songs": (
                .ok,
                Fixtures.page([Fixtures.song(1, "15 Step", track: 1), Fixtures.song(2, "Bodysnatchers", track: 2)])
            ),
        ]
        let list = try await library.album(50, roomy)
        XCTAssertEqual(list.title, "Album")
        XCTAssertEqual(list.header?.subtitle, "Radiohead \u{B7} 2007")
        XCTAssertEqual(list.header?.play, .album(50))
        let rows = list.sections.flatMap(\.rows)
        XCTAssertEqual(rows.map(\.text), ["15 Step", "Bodysnatchers"])
        XCTAssertEqual(rows.map(\.detail), [nil, nil])
        XCTAssertEqual(rows.map(\.art), [nil, nil])
        XCTAssertEqual(rows.map(\.action), [.playTrack(0), .playTrack(1)])
        XCTAssertEqual(rows[1].marker, .song(2))
        XCTAssertEqual(list.queue?.songs.map(\.id), [1, 2])
        XCTAssertEqual(list.queue?.source, "In Rainbows")
    }

    func testAPlaylistPlaysWithItsIdSoItCountsAsPlayed() async throws {
        transport.routes = [
            "GET /profiles/1/playlists/3": (.ok, Fixtures.playlist(3, "Road trip", count: 2)),
            "GET /profiles/1/playlists/3/play-order": (
                .ok, Fixtures.page([Fixtures.row(entry: 1, song: 9), Fixtures.row(entry: 1, song: 10)])
            ),
        ]
        let queue = try await library.queue(for: .playlist(3))
        XCTAssertEqual(queue.songs.map(\.id), [9, 10], "an album entry plays as the songs the server expands it to")
        XCTAssertEqual(queue.source, "Road trip")
        XCTAssertEqual(queue.playlistId, 3)
        let list = try await library.playlist(3, roomy)
        XCTAssertEqual(list.header?.subtitle, "2 songs")
        XCTAssertEqual(list.sections.flatMap(\.rows).first?.detail, "Radiohead")
    }

    func testAnUnreachableServerIsThrownAsSuch() async {
        transport.failure = URLError(.cannotConnectToHost)
        do {
            _ = try await library.recent(roomy)
            XCTFail("expected a failure")
        } catch {
            XCTAssertEqual(error as? AppError, .unreachable)
        }
    }

    func testUpNextListsTheUpcomingSongsAndJumps() {
        let queue = AudioQueue(Fixtures.songs(4), start: 1, source: "In Rainbows")
        let list = CarPlayLibrary.upNext(queue, maxItems: 2)
        XCTAssertEqual(list.title, "Up next")
        let rows = list.sections.flatMap(\.rows)
        XCTAssertEqual(rows.map(\.text), ["Song 3", "Song 4"])
        XCTAssertEqual(rows.first?.detail, "Radiohead")
        XCTAssertEqual(rows.first?.action, .jump(queue.upNext[0].id))
        XCTAssertEqual(CarPlayLibrary.upNext(queue, maxItems: 1).sections.flatMap(\.rows).count, 1)
    }

    func testUpNextIsOffWhenNowPlayingIsTheFifthTemplate() {
        XCTAssertTrue(CarPlayLibrary.upNextEnabled(depth: 4))
        XCTAssertFalse(CarPlayLibrary.upNextEnabled(depth: 5))
    }

    func testMarkersFollowTheSongPlaying() {
        let song = Fixtures.songs(2)[1]
        XCTAssertTrue(CarPlayRow.Marker.album(50).matches(song))
        XCTAssertTrue(CarPlayRow.Marker.song(2).matches(song))
        XCTAssertFalse(CarPlayRow.Marker.song(1).matches(song))
        XCTAssertFalse(CarPlayRow.Marker.album(50).matches(nil))
    }
}
