import Foundation
import GRDB
import RabbitEarsAPI
import XCTest

@testable import RabbitEarsKit

/// Reads at 15:12 UTC on Sunday 15 November 2026, of `stationHousehold`.
@MainActor
final class StationsModelTests: XCTestCase {
    let transport = RoutingTransport()

    private func at(_ instant: String) -> Date { ISO8601DateFormatter().date(from: instant)! }

    func testAListIsTheStationsSharedWithTheProfileByNameOfItsKind() async throws {
        let model = stationsModel(try stationHousehold())
        let all = await model.list()
        XCTAssertEqual(all?.map(\.id), [8, 5, 11, 10])
        let movies = await model.list(.movies)
        XCTAssertEqual(movies?.map(\.id), [5, 11])
        let robins = await stationsModel(try stationHousehold(), profile: 2).list()
        XCTAssertEqual(robins?.map(\.id), [8, 7, 5, 10])
        XCTAssertTrue(transport.sent.isEmpty, "nothing is asked of the server")
    }

    /// Another household's station arrives with its playlist and programs,
    /// and its owner's household on the row, but not its owner.
    func testAServerWideStationOfAnotherHouseholdReadsWithoutItsOwner() async throws {
        let replica = try stationHousehold { db in
            try db.station(14, "Far Away", owner: 111, visibility: "server", household: 202)
            try db.entry(6, station: 14, item: 22)
            try db.program(42, station: 14, item: 22, starts: "2026-11-15T15:00:00Z", ends: "2026-11-15T16:30:00Z")
            try db.station(15, "Next Door", owner: 112, visibility: "household", household: 202)
        }
        let model = stationsModel(replica)
        let all = await model.list()
        XCTAssertEqual(all?.map(\.id), [8, 14, 5, 11, 10])
        let far = try await unwrapped(await model.station(14))
        XCTAssertEqual(far.ownerId, 111)
        XCTAssertEqual(far.householdId, 202)
        XCTAssertFalse(model.isOwner(far))
        XCTAssertEqual(far.onAir.now?.itemId, 22)
        let schedule = await model.schedule(of: 14)
        XCTAssertEqual(schedule?.map(\.itemId), [22])
        let kids = await stationsModel(replica, profile: 3).list(.movies)
        XCTAssertEqual(kids?.map(\.id), [14], "a kid sees it by its play order")
        let nextDoor = await model.station(15)
        XCTAssertNil(nextDoor, "another household's own")
    }

    func testAStationReadsAsTheServerAnswersIt() async throws {
        let station = try await unwrapped(await stationsModel(try stationHousehold()).station(5))
        XCTAssertEqual(station.name, "The Big Screen")
        XCTAssertEqual(station.kind, .movies)
        XCTAssertEqual(station.ownerId, 1)
        XCTAssertEqual(station.householdId, 7)
        XCTAssertEqual(station.playlistId, 105)
        XCTAssertEqual(station.order, .random)
        XCTAssertEqual(station.visibility, .household)
        XCTAssertEqual(station.timing, .hour)
        XCTAssertEqual(station.rating, "PG-13")
        XCTAssertEqual(station.days, [.monday, .friday])
        XCTAssertEqual(
            station.times, [StationTimeRange(from: "10:00", to: "11:00"), StationTimeRange(from: "22:00", to: "02:00")])
        XCTAssertEqual(station.imageUrl, "/api/v1/stations/5/image?v=77")
        XCTAssertEqual(station.createdAt, at("2026-01-01T00:00:00Z"))
        XCTAssertEqual(station.updatedAt, at("2026-01-02T00:00:00Z"))
        let onAir = station.onAir
        XCTAssertEqual(onAir.status, .onAir)
        XCTAssertEqual(onAir.now?.itemId, 20)
        XCTAssertEqual(onAir.now?.item?.metadata?.contentRating, "PG-13")
        XCTAssertEqual(onAir.now?.durationMs, 112 * 60_000)
        XCTAssertEqual(onAir.now?.startsAt, at("2026-11-15T14:00:00Z"))
        XCTAssertEqual(onAir.now?.endsAt, at("2026-11-15T15:52:00Z"))
        XCTAssertEqual(onAir.positionMs, 72 * 60_000)
        XCTAssertEqual(onAir.next?.itemId, 21)
        XCTAssertEqual(onAir.upNext.map(\.itemId), [21, 23, 22])
        let episode = onAir.upNext[1]
        XCTAssertEqual(episode.kind, .episode)
        XCTAssertEqual(episode.item?.parsedTitle, "Hatchlings")
        XCTAssertEqual(episode.show?.id, 90, "an episode's show is its season's parent")
        XCTAssertEqual(StationText.title(episode), "Pocket Dragons · S2 E5")
        XCTAssertNil(episode.song)
    }

    func testASongIsAnsweredAsMusicAnswersIt() async throws {
        let station = try await unwrapped(await stationsModel(try stationHousehold()).station(8))
        XCTAssertEqual(station.kind, .music)
        XCTAssertNil(station.imageUrl)
        XCTAssertNil(station.rating)
        let song = try XCTUnwrap(station.onAir.now?.song)
        XCTAssertNil(station.onAir.now?.item)
        XCTAssertEqual(station.onAir.now?.kind, .song)
        XCTAssertEqual(song.id, 30)
        XCTAssertEqual(song.albumId, 50)
        XCTAssertEqual(song.albumTitle, "In Rainbows")
        XCTAssertEqual(song.albumArtistId, 40)
        XCTAssertEqual(song.artistId, 40)
        XCTAssertEqual(song.artistName, "Radiohead")
        XCTAssertEqual(song.title, "Paper Lanterns")
        XCTAssertEqual(song.libraryId, 3)
        XCTAssertEqual(song.discNumber, 1)
        XCTAssertEqual(song.trackNumber, 4)
        XCTAssertEqual(song.durationMs, 240_000)
        XCTAssertEqual(song.year, 2007)
        XCTAssertEqual(song.codec, "flac")
        XCTAssertTrue(song.lossless)
        XCTAssertEqual(station.onAir.positionMs, 2 * 60_000)
    }

    func testNothingOnIsBetweenProgramsInsideTheScheduleAndOffScheduleOutsideIt() async throws {
        let model = stationsModel(try stationHousehold())
        let zebra = try await unwrapped(await model.station(10))
        XCTAssertEqual(zebra.onAir.status, .offSchedule)
        XCTAssertNil(zebra.onAir.now)
        XCTAssertNil(zebra.onAir.positionMs)
        XCTAssertEqual(zebra.onAir.upNext, [])
        let yard = try await unwrapped(await model.station(11))
        XCTAssertEqual(yard.onAir.status, .betweenPrograms)
        let late = try await unwrapped(
            await stationsModel(try stationHousehold(), now: "2026-11-15T20:30:00Z").station(10))
        XCTAssertEqual(late.onAir.status, .betweenPrograms)
    }

    func testAScheduleOpensOnItsDaysAndARangeRunsPastMidnight() {
        let saturdayLate = [6]
        let lateNight = [(1320, 120)]
        let open = { (days: [Int], times: [(Int, Int)], at: String) in
            StationRows.open(
                days: days, times: times.map { (from: $0.0, to: $0.1) }, at: self.at(at), calendar: utcCalendar)
        }
        XCTAssertTrue(open(saturdayLate, lateNight, "2026-11-15T01:00:00Z"), "Saturday's range runs into Sunday")
        XCTAssertFalse(open(saturdayLate, lateNight, "2026-11-15T02:00:00Z"))
        XCTAssertFalse(open(saturdayLate, lateNight, "2026-11-15T23:30:00Z"), "not on Sunday")
        XCTAssertTrue(open(saturdayLate, lateNight, "2026-11-14T22:00:00Z"))
        XCTAssertTrue(open([0], [], "2026-11-15T09:00:00Z"), "a day without ranges is all day")
        XCTAssertFalse(open([0], [], "2026-11-16T09:00:00Z"))
        XCTAssertTrue(open([], [], "2026-11-16T09:00:00Z"), "continuous")
        XCTAssertTrue(open([], [(600, 660)], "2026-11-16T10:59:00Z"))
        XCTAssertFalse(open([], [(600, 660)], "2026-11-16T11:00:00Z"))
    }

    /// A kid sees a station only when it may see all its playlist plays, and
    /// a profile hiding kids' content one with something else in it.
    func testKidsAndProfilesHidingKidsContentSeeStationsByTheirPlayOrder() async throws {
        let replica = try stationHousehold { db in
            try db.station(12, "Kids corner")
            try db.entry(3, station: 12, item: 21)
            try db.entry(4, station: 12, item: 22)
            try db.program(40, station: 12, item: 20, starts: "2026-11-15T15:00:00Z", ends: "2026-11-15T16:00:00Z")
            try db.program(41, station: 12, item: 22, starts: "2026-11-15T16:00:00Z", ends: "2026-11-15T17:30:00Z")
            try db.station(13, "Tots")
            try db.entry(5, station: 13, item: 22)
        }
        let kid = stationsModel(replica, profile: 3)
        let kids = await kid.list(.movies)
        XCTAssertEqual(kids?.map(\.id), [12, 13])
        let corner = try await unwrapped(await kid.station(12))
        XCTAssertEqual(corner.onAir.status, .betweenPrograms, "a program the kid may not see is left out")
        XCTAssertNil(corner.onAir.now)
        XCTAssertEqual(corner.onAir.upNext.map(\.itemId), [22])
        let unseen = await kid.station(5)
        XCTAssertNil(unseen)
        let hiding = await stationsModel(replica, profile: 4).list(.movies)
        XCTAssertEqual(hiding?.map(\.id), [12, 5])
    }

    func testACoverOfATitleShowsWhileItIsInThePlaylistAndSeen() async throws {
        let replica = try stationHousehold { db in
            try db.cover(78, station: 11, item: 21)
            try db.entry(6, station: 11, item: 21)
            try db.cover(79, station: 10, item: 21)
            try db.station(12, "Kids corner")
            try db.entry(3, station: 12, item: 21)
            try db.entry(4, station: 12, item: 22)
            try db.cover(80, station: 12, item: 22)
        }
        let model = stationsModel(replica)
        let images = [await model.station(11), await model.station(10), await model.station(12)].map { $0?.imageUrl }
        XCTAssertEqual(images, ["/api/v1/stations/11/image?v=78", nil, "/api/v1/stations/12/image?v=80"])
        let hiding = try await unwrapped(await stationsModel(replica, profile: 4).station(12))
        XCTAssertNil(hiding.imageUrl, "Moon Pie is kids' content, which Jo hides")
    }

    func testAProgramNamesItsEditionOnlyBesideAnother() async throws {
        let replica = try stationHousehold { db in
            try db.edition(200, item: 20, runtime: 7_200_000)
            try db.edition(201, item: 20, fileMs: 8_970_000)
            try db.edition(210, item: 21, tag: "Director's Cut")
            try db.edition(211, item: 21)
            try db.edition(220, item: 22)
            try db.execute(sql: "UPDATE station_program SET edition_id = 201 WHERE id = 20")
            try db.execute(sql: "UPDATE station_program SET edition_id = 211 WHERE id = 21")
            try db.execute(sql: "UPDATE station_program SET edition_id = 210 WHERE id = 23")
            try db.execute(sql: "UPDATE station_program SET item_id = 21 WHERE id = 23")
            try db.execute(sql: "UPDATE station_program SET edition_id = 220 WHERE id = 22")
        }
        let onAir = try await unwrapped(await stationsModel(replica).station(5)).onAir
        XCTAssertEqual(onAir.now?.editionId, 201)
        XCTAssertEqual(onAir.now?.editionName, "150-minute cut", "two untagged cuts are named by length")
        XCTAssertEqual(onAir.upNext.map(\.editionName), ["Standard", "Director's Cut", nil])
    }

    func testTheScheduleIsTheProgramsOverlappingThisDevicesDay() async throws {
        let replica = try stationHousehold { db in
            try db.program(18, station: 5, item: 22, starts: "2026-11-14T23:00:00Z", ends: "2026-11-15T00:30:00Z")
            try db.program(24, station: 5, item: 22, starts: "2026-11-16T00:30:00Z", ends: "2026-11-16T02:00:00Z")
        }
        let utc = await stationsModel(replica).schedule(of: 5)
        XCTAssertEqual(utc?.map(\.itemId), [22, 21, 20, 21, 23, 22], "from the one that started yesterday")
        var pacific = utcCalendar
        pacific.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let west = await stationsModel(replica, calendar: pacific).schedule(of: 5)
        XCTAssertEqual(
            west?.map(\.startsAt),
            [
                "2026-11-15T12:00:00Z", "2026-11-15T14:00:00Z", "2026-11-15T16:00:00Z", "2026-11-15T18:30:00Z",
                "2026-11-15T19:00:00Z", "2026-11-16T00:30:00Z",
            ].map(at), "the device's day, 08:00 to 08:00 UTC")
        let kid = stationsModel(replica, profile: 3)
        let unseen = await kid.schedule(of: 5)
        XCTAssertNil(unseen)
        let tunes = await kid.schedule(of: 8)
        XCTAssertEqual(tunes?.map(\.itemId), [30])
        XCTAssertTrue(transport.sent.isEmpty)
    }

    func testOnlyTheOwnerOwnsIt() throws {
        let model = stationsModel(try stationHousehold())
        XCTAssertTrue(model.isOwner(Fixtures.decode(Fixtures.bigScreen)))
        XCTAssertFalse(model.isOwner(Fixtures.decode(Fixtures.station(8, "Theirs", owner: 2))))
    }
}

/// Edits: queued where the operation replays, else sent, then caught up with.
@MainActor
final class StationsModelWriteTests: XCTestCase {
    let transport = RoutingTransport()

    func testSaveCreatesThenReplacesOnTheServerAndCatchesUp() async throws {
        transport.routes["POST /stations"] = (.created, Fixtures.station(9, "Late show"))
        transport.routes["PUT /stations/9"] = (.ok, Fixtures.station(9, "Later show"))
        let model = stationsModel(try stationHousehold(), transport: transport)
        var form = StationForm(kind: .music)
        form.name = "Late show"
        let made = await model.save(form)
        XCTAssertEqual(made?.id, 9)
        XCTAssertNil(transport.json(.post, "/stations")?["playlistId"])
        XCTAssertEqual(transport.json(.post, "/stations")?["kind"] as? String, "music")
        XCTAssertEqual(transport.paths(.get), ["/sync/changes"], "the new rows come through sync")
        form.name = "Later show"
        let saved = await model.save(form, as: 9)
        XCTAssertEqual(saved?.name, "Later show")
        XCTAssertEqual(transport.json(.put, "/stations/9")?["name"] as? String, "Later show")
        XCTAssertEqual(transport.paths(.get), ["/sync/changes", "/sync/changes"])
        XCTAssertNil(model.error)
    }

    func testARefusedSaveShowsEachFieldsMessage() async throws {
        transport.routes["POST /stations"] = (
            .badRequest,
            #"{"code":"bad_request","message":"invalid request","#
                + #""fields":[{"field":"name","message":"too long"}]}"#
        )
        let model = stationsModel(try stationHousehold(), transport: transport)
        var form = StationForm(kind: .movies)
        form.name = "Late show"
        let made = await model.save(form)
        XCTAssertNil(made)
        XCTAssertEqual(model.fieldErrors, ["name": "too long"])
        XCTAssertEqual(transport.paths(.get), [], "nothing to catch up with")
        transport.routes["POST /stations"] = (.created, Fixtures.station(9, "Late show"))
        _ = await model.save(form)
        XCTAssertEqual(model.fieldErrors, [:])
    }

    /// Rescheduling is queued, offline too; the new programs arrive by sync
    /// once the server has made them.
    func testRescheduleIsQueued() async throws {
        let replica = try stationHousehold()
        let model = stationsModel(replica, transport: transport)
        let rescheduled = await model.reschedule(5)
        XCTAssertTrue(rescheduled)
        XCTAssertTrue(transport.sent.isEmpty, "nothing is sent until the queue flushes")
        let queued = try await queued(replica)
        XCTAssertEqual(queued, ["rescheduleStation POST /stations/5/reschedule 1 station 5 -"])
        let station = await model.station(5)
        XCTAssertEqual(station?.onAir.now?.itemId, 20, "what is on stays until the server's schedule arrives")
    }

    /// Deleting is queued: the station is gone at once, offline too, and
    /// the server hears of it when the queue is sent.
    func testDeleteIsQueuedAndGoneAtOnce() async throws {
        let replica = try stationHousehold()
        let model = stationsModel(replica, transport: transport)
        await model.loadMine()
        XCTAssertEqual(model.mine.map(\.id), [5, 11])
        let deleted = await model.delete(5)
        XCTAssertTrue(deleted)
        XCTAssertEqual(model.mine.map(\.id), [11])
        let left = await model.list()
        XCTAssertEqual(left?.map(\.id), [8, 11, 10])
        let station = await model.station(5)
        XCTAssertNil(station)
        XCTAssertTrue(transport.sent.isEmpty, "nothing is sent until the queue flushes")
        let queued = try await queued(replica)
        XCTAssertEqual(queued, ["deleteStation DELETE /stations/5 1 station 5 -"])
    }

    /// Each queued action with its touched rows, as `operation method path profile table key1 key2`.
    private func queued(_ replica: Replica) async throws -> [String] {
        try await replica.read { db in
            try String.fetchAll(
                db,
                sql: """
                    SELECT a.operation_id || ' ' || a.method || ' ' || a.path || ' ' || a.profile_id || ' '
                        || t.table_name || ' ' || t.key1 || ' ' || COALESCE(t.key2, '-')
                    FROM queue.action a JOIN queue.action_touch t ON t.action = a.seq ORDER BY a.seq, t.rowid
                    """)
        }
    }

    /// Nothing is written when a program starts or ends, so a load wakes
    /// the boards once at the soonest such moment among what it read.
    func testALoadWakesTheBoardsOnceAtTheNextProgramBoundary() async throws {
        let app = try SyncedApp { db in
            try db.account(1, "Avery")
            try db.item(20, "movie", "The Lantern Keeper")
            try db.item(21, "movie", "Salt and Ember")
            try db.station(5, "The Big Screen")
            try db.program(20, station: 5, item: 20, starts: "2026-11-15T14:00:00Z", ends: "2026-11-15T15:52:00Z")
            try db.program(21, station: 5, item: 21, starts: "2026-11-15T16:00:00Z", ends: "2026-11-15T18:18:00Z")
            try db.station(6, "Kitchen Radio", kind: "music", timing: "continuous")
            try db.program(30, station: 6, item: 21, starts: "2026-11-15T15:50:00Z", ends: "2026-11-15T16:05:00Z")
        }
        defer { app.remove() }
        let sync = try await app.synced()
        var asked: [Date] = []
        let (released, release) = AsyncStream.makeStream(of: Void.self)
        let model = stationsModel(sync.replica, now: "2026-11-15T15:55:00Z") { date in
            asked.append(date)
            for await _ in released { return }
            throw CancellationError()
        }
        _ = await model.list()
        _ = await model.station(6)
        await app.until { !asked.isEmpty }
        let start = ISO8601DateFormatter().date(from: "2026-11-15T16:00:00Z")
        XCTAssertEqual(asked, [start], "one wake, at Salt and Ember's start")

        let before = app.model.live.stations
        release.yield()
        await app.until { app.model.live.stations > before }
        XCTAssertEqual(app.model.live.stations, before + 1)
        _ = await model.list()
        await app.until { asked.count == 2 }
        XCTAssertEqual(asked.count, 2, "the next load wakes again")
        release.finish()
    }
}

/// XCTUnwrap for a value an `await` reads.
func unwrapped<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) async throws -> T {
    try XCTUnwrap(value, file: file, line: line)
}
