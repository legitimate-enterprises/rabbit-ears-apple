import Foundation
import GRDB
import RabbitEarsAPI
import XCTest

@testable import RabbitEarsKit

@MainActor
final class UpNextModelTests: XCTestCase {
    var transport: RoutingTransport!
    var client: Client!
    var fixture: ReplicaFixture!
    let avery = Fixtures.decode(Fixtures.adult, as: Account.self)

    override func setUp() async throws {
        transport = RoutingTransport()
        client = ServerEndpoint(userInput: "192.168.1.9")!.client(token: "t", transport: transport)
        fixture = ReplicaFixture()
    }

    override func tearDown() { fixture.remove() }

    /// Avery (1) and Sam (2). Alpha's S1 E2 has its file gone; Dune comes
    /// before Dune Part Two in TMDB's collection; Shop's videos are by
    /// publish date; Sam's playlist 4 is not shared with Avery.
    private func library(_ rows: (Database) throws -> Void = { _ in }) throws -> Replica {
        try fixture.v1 { db in
            try db.account(1, "Avery")
            try db.account(2, "Sam")
            try db.item(10, "show", "Alpha", rating: "TV-14")
            try db.item(11, "season", "Season 1", parent: 10, season: 1)
            try db.item(21, "episode", "Pilot", parent: 11, season: 1, episode: 1)
            try db.item(22, "episode", "Gone", parent: 11, season: 1, episode: 2)
            try db.item(23, "episode", "Third", parent: 11, season: 1, episode: 3)
            try db.playable(21)
            try db.playable(22, missing: true)
            try db.playable(23)
            try db.item(30, "movie", "Dune Part Two", rating: "PG-13", year: 2024)
            try db.item(31, "movie", "Dune", rating: "PG-13", year: 2021)
            try db.playable(30)
            try db.collection(6, "Dune", source: "tmdb", movies: [30, 31])
            try db.library(2, "youtube")
            try db.execute(
                sql: """
                    INSERT INTO item(id, library_id, parent_id, kind, parsed_title, added_at) VALUES
                        (\(sqlID(50)), \(sqlID(2)), NULL, 'channel', 'Shop', 0),
                        (\(sqlID(41)), \(sqlID(2)), \(sqlID(50)), 'video', 'New', 0),
                        (\(sqlID(40)), \(sqlID(2)), \(sqlID(50)), 'video', 'Old', 0);
                    INSERT INTO item_metadata(item_id, source, published_at)
                        VALUES (\(sqlID(41)), 'local', 2), (\(sqlID(40)), 'local', 1);
                    """)
            try db.playable(41)
            try rows(db)
        }
    }

    private func next(_ ended: PlayRequest, in replica: Replica) async -> UpNextModel? {
        await UpNextModel.load(after: ended, replica: replica, profile: avery)
    }

    private func request(_ id: UID, _ kind: String) -> PlayRequest {
        PlayRequest(item: Fixtures.decode(Fixtures.item(id, kind, "T\(id)"), as: Item.self))
    }

    func testTheNextEpisodeWithAFilePlaysFromTheStartInTheSamePlayer() async throws {
        let ended = request(21, "episode")
        let loaded = await next(ended, in: try library())
        let next = try XCTUnwrap(loaded)
        XCTAssertEqual(next.title, "Alpha · S1 E3 · Third", "over the one whose file is gone")
        XCTAssertEqual(next.request.item.id, 23)
        XCTAssertEqual(next.request.positionMs, 0)
        XCTAssertNil(next.request.editionId)
        XCTAssertEqual(next.request.id, ended.id)
        XCTAssertTrue(next.autoplay, "on unless the profile turned it off")
        XCTAssertTrue(transport.sent.isEmpty, "the replica answers")
    }

    func testAFilmIsFollowedByTheNextInItsCollectionAndAVideoByTheNextPublished() async throws {
        let replica = try library()
        let film = await next(request(31, "movie"), in: replica)
        XCTAssertEqual(film?.title, "Dune Part Two")
        XCTAssertEqual(film?.request.item.id, 30)
        let video = await next(request(40, "movie"), in: replica)
        XCTAssertEqual(video?.title, "New")
        XCTAssertEqual(video?.request.item.id, 41)
        XCTAssertEqual(video?.request.item.libraryId, 2)
    }

    func testAPlaylistPlaysItsNextRowWithAFileNamingItsEdition() async throws {
        let replica = try library { db in
            for number in 60...62 { try db.item(.n(number), "movie", "T\(number)", rating: "PG") }
            try db.playable(60)
            try db.playable(61, missing: true)
            try db.edition(620, of: 62)
            try db.file(620, in: 620)
            try db.edition(621, of: 62, tag: "Extended")
            try db.file(621, in: 621)
            try db.playlist(3, of: 1, items: [(60, nil), (61, nil), (62, 621), (60, nil)])
        }
        let rows = ([60, 61, 62, 60] as [UID]).map {
            Fixtures.decode(Fixtures.row(entry: $0, item: $0, kind: "movie"), as: PlayOrderRow.self)
        }
        let queue = try XCTUnwrap(VideoQueue(rows, start: 0, playlistId: 3))
        let loaded = await next(PlayRequest(item: queue.current, queue: queue), in: replica)
        let next = try XCTUnwrap(loaded)
        XCTAssertEqual(next.title, "T62 · Extended")
        XCTAssertEqual(next.request.queue?.index, 2)
        XCTAssertEqual(next.request.item.id, 62)

        let fromLast = try XCTUnwrap(VideoQueue(rows, start: 3, playlistId: 3))
        let last = await self.next(PlayRequest(item: fromLast.current, queue: fromLast), in: replica)
        XCTAssertNil(last, "the last row has nothing after it")
    }

    func testAPlaylistNotSharedWithTheProfileOffersNothing() async throws {
        let replica = try library { db in
            for number in 60...61 { try db.item(.n(number), "movie", "T\(number)", rating: "PG") }
            try db.playable(61)
            try db.playlist(4, of: 2, items: [(60, nil), (61, nil)])
        }
        let rows = ([60, 61] as [UID]).map {
            Fixtures.decode(Fixtures.row(entry: $0, item: $0, kind: "movie"), as: PlayOrderRow.self)
        }
        let queue = try XCTUnwrap(VideoQueue(rows, start: 0, playlistId: 4))
        let loaded = await next(PlayRequest(item: queue.current, queue: queue), in: replica)
        XCTAssertNil(loaded)
    }

    func testNothingNextOrNothingReadIsNil() async throws {
        let last = await next(request(23, "episode"), in: try library())
        XCTAssertNil(last)
        let empty = ReplicaFixture()
        defer { empty.remove() }
        let unread = await next(request(21, "episode"), in: try empty.open())
        XCTAssertNil(unread)
    }

    func testTheCountdownRunsOnlyWithAutoplayOn() async {
        let request = PlayRequest(item: Fixtures.decode(Fixtures.item(22, "movie", "T22"), as: Item.self))
        let on = UpNextModel(title: "T22", request: request, autoplay: true)
        var ticks = 0
        let played = await on.countdown { ticks += 1 }
        XCTAssertTrue(played)
        XCTAssertEqual(ticks, UpNextModel.countdownSeconds)
        XCTAssertEqual(on.secondsLeft, 0)

        let off = UpNextModel(title: "T22", request: request, autoplay: false)
        let waited = await off.countdown { XCTFail("no countdown with Autoplay off") }
        XCTAssertFalse(waited)
        XCTAssertNil(off.secondsLeft)

        let cancelled = await on.countdown { throw CancellationError() }
        XCTAssertFalse(cancelled)
    }

    func testTheCardsCheckboxSavesAutoplayForTheProfile() async throws {
        let app = try SyncedApp { try $0.member(1, "Avery") }
        defer { app.remove() }
        app.routes.routes["POST /profiles/\(UID.n(1))/unlock"] = (.noContent, "")
        let sync = try await app.synced()
        let model = app.model!
        try await model.choose(try XCTUnwrap(model.profiles.first))
        let request = PlayRequest(item: Fixtures.decode(Fixtures.item(22, "movie", "T22"), as: Item.self))
        let next = UpNextModel(title: "T22", request: request, autoplay: true)
        await next.setAutoplay(false, model: model)
        XCTAssertFalse(next.autoplay)
        _ = await sync.queue.flush()
        XCTAssertEqual(app.sentBodies().first?["autoplay"] as? Bool, false)
    }
}
