import Foundation
import GRDB
import RabbitEarsAPI
import XCTest

@testable import RabbitEarsKit

@MainActor
final class CatalogModelTests: XCTestCase {
    var fixture: ReplicaFixture!

    override func setUp() { fixture = ReplicaFixture() }
    override func tearDown() { fixture.remove() }

    /// Avery an adult (1), Robin hiding kids' content (2), Kit a kid on
    /// ratings to PG and TV-Y (3), Ash a kid on an allow list of Dune and
    /// Bluey (4), over the same titles; Bluey's tree and a G movie are kids'.
    private func household(_ rows: @escaping (Database) throws -> Void = { _ in }) throws -> Replica {
        try fixture.v1 { db in
            try db.account(1, "Avery")
            try db.account(2, "Robin", hidingKids: true)
            try db.account(3, "Kit", kind: "kid", movies: "PG", tv: "TV-Y")
            try db.account(4, "Ash", kind: "kid", filter: "allow_list")
            try db.allow(20, for: 4)
            try db.allow(30, for: 4)
            try db.item(20, "movie", "Dune", rating: "PG-13")
            try db.item(1, "movie", "Tots", rating: "G")
            try db.item(2, "movie", "Paddington", rating: "PG")
            try db.item(10, "show", "Severance", rating: "TV-MA")
            try db.item(11, "season", "Season 1", parent: 10, season: 1)
            try db.item(12, "episode", "Good News", parent: 11, season: 1, episode: 1)
            try db.item(30, "show", "Bluey", rating: "TV-Y")
            try db.item(31, "season", "Season 1", parent: 30, season: 1)
            try db.item(32, "episode", "Hotel", parent: 31, season: 1, episode: 1)
            try rows(db)
        }
    }

    private let titles: [UID] = [1, 2, 10, 11, 12, 20, 30, 31, 32]

    private func model(
        _ replica: Replica, _ profile: UID, transport: RoutingTransport = RoutingTransport()
    ) -> CatalogModel {
        CatalogModel(
            client: ServerEndpoint.default.client(token: "t", transport: transport), replica: replica,
            profileId: profile)
    }

    private func loaded(_ replica: Replica, _ profile: UID) async -> CatalogModel {
        let model = model(replica, profile)
        await model.load()
        return model
    }

    func testEachProfileReadsWhatItsAudienceSeesAndOnlyItsOwnWatchState() async throws {
        let replica = try household { db in
            try db.watch(2, for: 1, position: 60_000)
            try db.watch(2, for: 3, watched: true)
            try db.watch(20, for: 3, watched: true)
        }
        let avery = await loaded(replica, 1)
        XCTAssertNil(avery.error)
        XCTAssertTrue(avery.loaded)
        XCTAssertEqual(titles.filter { avery.catalog.item($0) != nil }, titles)
        XCTAssertTrue(avery.catalog.isInProgress(2))
        XCTAssertFalse(avery.catalog.isWatched(20), "Kit's mark is Kit's")

        let robin = await loaded(replica, 2)
        XCTAssertEqual(robin.catalog.grid(.movie).map(\.id).sorted(), [2, 20])
        XCTAssertEqual(robin.catalog.grid(.show).map(\.id), [10])
        XCTAssertEqual(robin.catalog.grid(.movie, filter: .kids).map(\.id), [1], "held apart for the Kids pill")
        XCTAssertEqual(robin.catalog.episodes(under: 30).map(\.id), [32])

        let kit = await loaded(replica, 3)
        XCTAssertEqual(titles.filter { kit.catalog.item($0) != nil }, [1, 2, 30, 31, 32])
        XCTAssertTrue(kit.catalog.isWatched(2))
        XCTAssertFalse(kit.catalog.isWatched(20), "a mark on what Kit cannot see is not read")

        let ash = await loaded(replica, 4)
        XCTAssertEqual(titles.filter { ash.catalog.item($0) != nil }, [20, 30, 31, 32])
    }

    func testBeforeTheFirstSnapshotNothingIsLoadedAndNothingIsWrong() async throws {
        let model = model(try fixture.open(), 1)
        await model.load()
        XCTAssertFalse(model.loaded)
        XCTAssertNil(model.error)
        XCTAssertEqual(model.revision, 0)
    }

    func testAMarkShowsAtOnceAndIsQueuedForTheServerAndAShowMarksEachEpisode() async throws {
        let replica = try household()
        let model = model(replica, 1)
        await model.load()
        await model.setWatched(true, for: try XCTUnwrap(model.catalog.item(20)))
        await model.setWatched(true, for: try XCTUnwrap(model.catalog.item(10)))
        XCTAssertNil(model.error)
        XCTAssertTrue(model.catalog.isWatched(20))
        XCTAssertTrue(model.catalog.isWatched(12))
        let queued = try await replica.read {
            try String.fetchAll($0, sql: "SELECT operation_id || ' ' || path FROM queue.action ORDER BY seq")
        }
        XCTAssertEqual(
            queued,
            [
                "putWatchState /profiles/\(UID.n(1))/watch-state/\(UID.n(20))",
                "putWatchState /profiles/\(UID.n(1))/watch-state/\(UID.n(12))",
            ])

        let empty = ReplicaFixture()
        defer { empty.remove() }
        let unread = self.model(try empty.open(), 1)
        await unread.setWatched(true, for: try XCTUnwrap(model.catalog.item(20)))
        XCTAssertNotNil(unread.error, "nothing to mark before the first snapshot")
    }

    func testAfterPlayTheReplicasWatchStateStandsAndOneGoneIsForgotten() async throws {
        let replica = try household { try $0.watch(20, for: 1, position: 60_000) }
        let model = await loaded(replica, 1)
        XCTAssertTrue(model.catalog.isInProgress(20))
        try await replica.write {
            try $0.execute(sql: "UPDATE watch_state SET position_ms = 0, watched = 1 WHERE account_id = \(sqlID(1))")
        }
        await model.refreshWatchState(20)
        XCTAssertTrue(model.catalog.isWatched(20))
        XCTAssertFalse(model.catalog.isInProgress(20))
        try await replica.write { try $0.execute(sql: "DELETE FROM watch_state") }
        await model.refreshWatchState(20)
        XCTAssertFalse(model.catalog.isWatched(20))
    }

    func testAChangeToTheWatchedGroupRereadsEveryWatchStateAndALibraryChangeEverything() async throws {
        let replica = try household { db in
            try db.watch(20, for: 1, watched: true)
            try db.watch(2, for: 1, position: 60_000)
        }
        let model = await loaded(replica, 1)
        try await replica.write { db in
            try db.execute(sql: "DELETE FROM watch_state WHERE item_id = \(sqlID(20))")
            try db.watch(1, for: 1, watched: true)
            try db.watch(2, for: 2, watched: true)
        }
        await model.heard(.watched)
        XCTAssertFalse(model.catalog.isWatched(20))
        XCTAssertTrue(model.catalog.isWatched(1))
        XCTAssertTrue(model.catalog.isInProgress(2), "Robin's mark is Robin's")

        try await replica.write { try $0.item(40, "movie", "Flow", rating: "PG") }
        await model.heard(.playlists)
        XCTAssertNil(model.catalog.item(40))
        await model.heard(.library)
        XCTAssertNotNil(model.catalog.item(40))
    }

    func testPlayabilitySendsThePlayersSnapshotAndReadsTheVerdict() async throws {
        let playability = "POST /items/\(UID.n(20))/playability"
        let transport = RoutingTransport([
            playability: (
                .ok,
                #"{"verdict":"video_transcode","negotiated":{"verdict":"video_transcode","width":1920,"#
                    + #""height":1080,"bitrate":8000000,"encoder":"hardware"}}"#
            )
        ])
        let model = CatalogModel(client: ServerEndpoint.default.client(token: "t", transport: transport), profileId: 2)
        let facts = FakeCapabilities().current
        let result = await model.playability(20, facts: facts, server: .default)
        XCTAssertEqual(result?.verdict, .videoTranscode)
        XCTAssertEqual(Format.playability(try XCTUnwrap(result?.verdict)), "Transcode on this device")
        XCTAssertEqual(Format.playability(.directPlay), "Direct play on this device")
        let sent = Fixtures.decode(
            try XCTUnwrap(transport.body(.post, "/items/\(UID.n(20))/playability")), as: CapabilitySnapshot.self)
        XCTAssertEqual(sent, CapabilitySnapshotBuilder.snapshot(facts, server: .default, maxBitrate: nil))
        transport.routes[playability] = (.conflict, Fixtures.error("conflict"))
        let none = await model.playability(20, facts: facts, server: .default)
        XCTAssertNil(none)
    }

    func testSearchReadsTheReplicaAsTheProfileBrowses() async throws {
        let replica = try household { db in
            try db.item(21, "movie", "Dune Two", rating: "G")
            try db.item(22, "movie", "Paddington Dune", rating: "PG")
            try db.item(33, "show", "Dune Show", rating: "TV-Y")
            try db.execute(
                sql: """
                    UPDATE item_metadata SET title = 'Dune Day' WHERE item_id = \(sqlID(32));
                    INSERT INTO person(id, tmdb_id, name, profile_path) VALUES (\(sqlID(5)), 99, 'Denis Dune', NULL),
                        (\(sqlID(6)), 98, 'Dune Extra', '/x.jpg'), (\(sqlID(7)), NULL, 'Dune Local', NULL);
                    INSERT INTO credit(id, item_id, person_id, kind)
                        VALUES (\(sqlID(1)), \(sqlID(20)), \(sqlID(5)), 'crew'),
                            (\(sqlID(2)), \(sqlID(30)), \(sqlID(6)), 'cast');
                    """)
            try db.library(3, "music")
            try db.library(4, "youtube")
            try db.artist(40, "Sand Dune")
            try db.album(41, "Dunes", artist: 40)
            try db.song(42, "Dune Song", album: 41, track: 1)
            try db.song(43, "Sand Song", album: 41, track: 2)
            try db.channel(50, "Low Dune")
            try db.channel(51, "Dune Works")
            try db.video(52, "Over the dune", channel: 50)
            try db.video(53, "Dune walk", channel: 51)
            try db.channel(54, "Dune Empty")
        }
        let transport = RoutingTransport()
        let avery = model(replica, 1, transport: transport)
        let empty = await avery.search("  ")
        XCTAssertEqual(empty, .empty)
        XCTAssertTrue(transport.sent.isEmpty)

        let searched = await avery.search(" dune ")
        let found = try XCTUnwrap(searched)
        XCTAssertEqual(found.movies.map(\.id), [20, 21, 22], "those starting with it first")
        XCTAssertEqual(found.shows.map(\.id), [33])
        XCTAssertEqual(found.episodes.map(\.id), [32])
        XCTAssertEqual(found.people.map(\.id), [6, 7, 5])
        XCTAssertEqual(found.people.first?.profilePath, "/x.jpg")
        XCTAssertEqual(found.artists.map(\.id), [40])
        XCTAssertEqual(found.albums.map(\.id), [41])
        XCTAssertEqual(found.songs.map(\.id), [42])
        XCTAssertEqual(found.channels.map(\.id), [51, 50], "a channel with no videos is not listed")
        XCTAssertEqual(found.videos.map(\.id), [53, 52])
        XCTAssertEqual(found.sections, [.movies, .tv, .songs, .albums, .artists, .videos, .channels, .people])
        let limited = await avery.search("dune", limit: 1)
        let one = try XCTUnwrap(limited)
        XCTAssertEqual(one.channels.map(\.id), [51])
        XCTAssertEqual(one.videos.map(\.id), [53])
        XCTAssertTrue(transport.sent.isEmpty, "the server's search is not asked")

        let kit = model(replica, 3, transport: transport)
        let kidsSearched = await kit.search("dune", limit: 1)
        let kids = try XCTUnwrap(kidsSearched)
        XCTAssertEqual(kids.movies.map(\.id), [21], "Dune is PG-13, and one each")
        XCTAssertEqual(kids.shows.map(\.id), [33])
        XCTAssertEqual(kids.people.map(\.id), [6], "only those credited on what Kit sees")

        let unread = await model(Replica(directory: Fixtures.replicas), 1, transport: transport).search("dune")
        XCTAssertNil(unread)
    }

    func testKidsContentIsOverriddenThenLeftToTheRatingThroughTheQueue() async throws {
        let replica = try household()
        let model = await loaded(replica, 2)
        let item = try XCTUnwrap(model.catalog.item(20))
        await model.setKidsContent(true, for: item)
        XCTAssertEqual(model.catalog.item(20)?.kidsContent, true)
        XCTAssertEqual(model.catalog.item(20)?.kidsContentOverride, true)
        let pill = model.catalog.grid(.movie, filter: .kids).map(\.id)
        XCTAssertEqual(pill.sorted(), [1, 20], "Robin's Kids pill holds it now")
        await model.setKidsContent(nil, for: item)
        XCTAssertEqual(model.catalog.item(20)?.kidsContent, false)
        XCTAssertNil(model.catalog.item(20)?.kidsContentOverride)
        XCTAssertNil(model.error)
        let queued = try await replica.read {
            try String.fetchAll($0, sql: "SELECT operation_id || ' ' || path FROM queue.action ORDER BY seq")
        }
        XCTAssertEqual(
            queued,
            ["setKidsContent /items/\(UID.n(20))/kids-content", "clearKidsContent /items/\(UID.n(20))/kids-content"])
    }

    func testCreditsAndAPersonsTitlesAsTheProfileSeesThem() async throws {
        let replica = try household { db in
            try db.item(21, "movie", "Arrakis", rating: "PG")
            try db.person(5, "Zendaya", tmdb: 50, profilePath: "/z.jpg")
            try db.person(6, "Denis Villeneuve", tmdb: 60)
            try db.person(7, "Nobody Credited", tmdb: 70)
            try db.credit(1, item: 20, person: 6, kind: "crew", position: 0, job: "Director")
            try db.credit(2, item: 20, person: 5, kind: "cast", position: 1, character: "Chani")
            try db.credit(3, item: 20, person: 7, kind: "cast", position: 0, character: "")
            try db.credit(4, item: 21, person: 5, kind: "cast", position: 0, character: "Herself")
        }
        let avery = model(replica, 1)
        let loaded = await avery.credits(20)
        let credits = try XCTUnwrap(loaded)
        XCTAssertEqual(credits.cast.map(\.personId), [7, 5], "billing order")
        XCTAssertEqual(credits.cast.map(\.character), [nil, "Chani"])
        XCTAssertEqual(credits.cast.last?.profilePath, "/z.jpg")
        XCTAssertEqual(credits.crew.map(\.job), ["Director"])
        let found = await avery.person(5)
        XCTAssertEqual(found?.0.name, "Zendaya")
        XCTAssertEqual(found?.0.tmdbId, 50)
        XCTAssertEqual(found?.1.map(\.id), [21, 20], "by title")

        let kit = model(replica, 3)
        let kidCredits = await kit.credits(20)
        XCTAssertNil(kidCredits, "Dune is past Kit's ceiling")
        let kidFound = await kit.person(5)
        XCTAssertEqual(kidFound?.1.map(\.id), [21])
        let unseen = await kit.person(6)
        XCTAssertNil(unseen, "credited only on what Kit may not see")
    }

    func testCrewLinesNameEachJobOnceInCreditOrder() {
        let credits = Fixtures.decode(
            #"{"cast":[],"crew":[{"personId":"\#(UID.n(1))","name":"Ann","job":"Writer"},"#
                + #"{"personId":"\#(UID.n(2))","name":"Bo","job":"Director"},"#
                + #"{"personId":"\#(UID.n(3))","name":"Cy","job":"Writer"},{"personId":"\#(UID.n(4))","name":"Di"}]}"#,
            as: Credits.self)
        let lines = credits.crewLines
        XCTAssertEqual(lines.map(\.0), ["Writer", "Director", "Crew"])
        XCTAssertEqual(lines.map(\.1), ["Ann, Cy", "Bo", "Di"])
    }
}
