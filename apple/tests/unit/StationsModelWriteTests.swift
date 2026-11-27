import Foundation
import GRDB
import RabbitEarsAPI
import XCTest

@testable import RabbitEarsKit

/// Edits: queued where the operation replays, else sent, then caught up with.
@MainActor
final class StationsModelWriteTests: XCTestCase {
    let transport = RoutingTransport()

    /// Offline, a new station shows at once under the ids this device gave
    /// it, its playlist its own, and the queued call names the same ids.
    func testACreateShowsAtOnceOfflineUnderItsClientIds() async throws {
        transport.failure = URLError(.notConnectedToInternet)
        let replica = try stationHousehold()
        let model = stationsModel(replica, transport: transport)
        var form = StationForm(kind: .tv)
        form.name = " Late show "
        form.order = .random
        form.visibility = .household
        form.schedule = .chosen
        form.days = [.friday, .monday]
        form.times = [StationTimeRange(from: "22:00", to: "02:00"), StationTimeRange(from: "10:00", to: "11:00")]
        let made = try await unwrapped(await model.save(form))
        XCTAssertEqual(made.name, "Late show")
        XCTAssertEqual(made.kind, .tv)
        XCTAssertEqual(made.ownerId, 1)
        XCTAssertEqual(made.householdId, 7)
        XCTAssertEqual(made.order, .random)
        XCTAssertEqual(made.visibility, .household)
        XCTAssertEqual(made.timing, .halfHour)
        XCTAssertEqual(made.days, [.monday, .friday])
        XCTAssertEqual(made.times.map(\.from), ["10:00", "22:00"])
        XCTAssertNil(made.rating, "the server rates it as it schedules")
        XCTAssertEqual(made.onAir.upNext, [], "its programs arrive by sync")
        XCTAssertEqual(made.createdBy, 1)
        XCTAssertEqual(made.modifiedBy, 1)
        XCTAssertEqual(made.createdAt, made.modifiedAt)
        XCTAssertTrue(model.mine.contains(made))
        let listed = await model.list(.tv)
        XCTAssertEqual(listed?.map(\.id), [made.id, 10])

        let action = try await lastAction(replica)
        XCTAssertEqual(action.queued, "createStation POST /stations \(UID.n(1))")
        XCTAssertEqual(made.createdAt, action.at)
        let body = try action.body
        XCTAssertEqual(body["id"] as? String, "\(made.id)")
        XCTAssertEqual(body["ownPlaylistId"] as? String, "\(made.playlistId)")
        XCTAssertNil(body["playlistId"])
        let times = try XCTUnwrap(body["times"] as? [[String: Any]])
        let sent = Dictionary(uniqueKeysWithValues: times.map { ($0["from"] as? String ?? "", $0["id"] as? String) })
        XCTAssertEqual(sent, Dictionary(uniqueKeysWithValues: made.times.map { ($0.from, $0.id.map(\.description)) }))
        XCTAssertEqual(Set(made.times.compactMap(\.id)).count, 2)

        try await assertStoredRows(of: made, at: action.at, in: replica)

        let late = try XCTUnwrap(made.times.first { $0.from == "22:00" }?.id)
        let early = try XCTUnwrap(made.times.first { $0.from == "10:00" }?.id)
        let touched = try await self.touched(replica)
        XCTAssertEqual(
            touched,
            [
                "playlist \(made.playlistId)", "station \(made.id)", "station_day \(made.id) 1",
                "station_day \(made.id) 5", "station_time \(late)", "station_time \(early)",
            ], "ranges in the form's order")
        XCTAssertTrue(transport.sent.isEmpty, "nothing is sent until the queue flushes")
    }

    /// A replace keeps the id of a range left as it was, gives a changed one
    /// a new id, and rewrites the days; who made it and when stay.
    func testAReplaceKeepsAnUnchangedRangesIdAndRewritesTheRest() async throws {
        transport.failure = URLError(.notConnectedToInternet)
        let replica = try stationHousehold()
        let model = stationsModel(replica, transport: transport)
        var form = StationForm(try await unwrapped(await model.station(5)))
        form.name = "Bigger Screen"
        form.order = .playlist
        form.days = [.sunday]
        form.times = [StationTimeRange(from: "12:00", to: "13:00"), StationTimeRange(from: "22:00", to: "02:00")]
        let saved = try await unwrapped(await model.save(form, as: 5))
        XCTAssertEqual(saved.id, 5)
        XCTAssertEqual(saved.name, "Bigger Screen")
        XCTAssertEqual(saved.playlistId, 105, "a replace keeps the playlist")
        XCTAssertEqual(saved.order, .playlist)
        XCTAssertEqual(saved.days, [.sunday])
        XCTAssertEqual(saved.times.map(\.from), ["12:00", "22:00"])
        let kept = saved.times[1].id
        let fresh = try XCTUnwrap(saved.times[0].id)
        XCTAssertEqual(kept, 50, "22:00 to 02:00 is as it was")
        XCTAssertFalse([50, 51].contains(fresh))
        XCTAssertEqual(saved.createdAt, ISO8601DateFormatter().date(from: "2026-01-01T00:00:00Z"))
        XCTAssertNil(saved.createdBy)
        XCTAssertEqual(saved.modifiedBy, 1)

        let action = try await lastAction(replica)
        XCTAssertEqual(action.queued, "replaceStation PUT /stations/\(UID.n(5)) \(UID.n(1))")
        XCTAssertEqual(saved.modifiedAt, action.at)
        XCTAssertNil(try action.body["id"])
        XCTAssertNil(try action.body["ownPlaylistId"])
        let times = try XCTUnwrap(try action.body["times"] as? [[String: Any]])
        XCTAssertEqual(times.map { $0["id"] as? String }, ["\(fresh)", "\(UID.n(50))"])
        let ranges: [UID] = try await replica.read {
            try UID.fetchAll(
                $0, sql: "SELECT id FROM station_time WHERE station_id = ? ORDER BY id", arguments: [UID.n(5)])
        }
        XCTAssertEqual(Set(ranges), [50, fresh])
        let touched = try await self.touched(replica)
        XCTAssertEqual(
            touched,
            ["station \(UID.n(5))"] + [0, 1, 5].map { "station_day \(UID.n(5)) \($0)" }
                + ["station_time \(fresh)", "station_time \(UID.n(50))", "station_time \(UID.n(51))"],
            "the old days and ranges too")
        XCTAssertTrue(transport.sent.isEmpty)
    }

    func testAFormWithoutANameSavesNothing() async throws {
        let replica = try stationHousehold()
        let model = stationsModel(replica, transport: transport)
        let made = await model.save(StationForm(kind: .movies))
        XCTAssertNil(made)
        XCTAssertEqual(model.fieldErrors, [:])
        let queued = try await queued(replica)
        XCTAssertEqual(queued, [])
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
        XCTAssertEqual(
            queued, ["rescheduleStation POST /stations/\(UID.n(5))/reschedule \(UID.n(1)) station \(UID.n(5)) -"])
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
        XCTAssertEqual(queued, ["deleteStation DELETE /stations/\(UID.n(5)) \(UID.n(1)) station \(UID.n(5)) -"])
    }

    /// Each queued action with its touched rows, as `operation method path profile table key1 key2`.
    private func queued(_ replica: Replica) async throws -> [String] {
        try await replica.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT a.operation_id || ' ' || a.method || ' ' || a.path AS call, a.profile_id,
                        t.table_name || ' ' || t.key1 || ' ' || COALESCE(t.key2, '-') AS row
                    FROM queue.action a JOIN queue.action_touch t ON t.action = a.seq ORDER BY a.seq, t.rowid
                    """
            ).map { "\($0["call"] as String) \($0["profile_id"] as UID) \($0["row"] as String)" }
        }
    }

    /// The station, its own playlist, days and ranges as the create wrote them at `instant`.
    private func assertStoredRows(of made: Station, at instant: Date, in replica: Replica) async throws {
        let ms = Int64((instant.timeIntervalSince1970 * 1000).rounded())
        let (playlistId, rangeIds) = (made.playlistId, made.times.compactMap(\.id))
        try await replica.read { db in
            let station = try XCTUnwrap(
                Row.fetchOne(
                    db,
                    sql: """
                        SELECT playlist_id, created_at, modified_at, created_by, modified_by, rating, loop,
                            typeof(id) = 'blob' AND length(id) = 16 AS blob
                        FROM station WHERE id = ?
                        """, arguments: [made.id]))
            XCTAssertEqual(station["playlist_id"] as UID, playlistId)
            XCTAssertEqual([station["created_at"], station["modified_at"]] as [Int64], [ms, ms])
            XCTAssertEqual([station["created_by"], station["modified_by"]] as [UID?], [1, 1])
            XCTAssertNil(station["rating"] as String?)
            XCTAssertNil(station["loop"] as Int?, "the server keeps the loop")
            XCTAssertTrue(station["blob"] as Bool, "a 16-byte id")
            let playlist = try XCTUnwrap(
                Row.fetchOne(
                    db,
                    sql: """
                        SELECT account_id, name, kind, station_owned, last_played_at, created_at, modified_at,
                            created_by, modified_by FROM playlist WHERE id = ?
                        """, arguments: [playlistId]))
            XCTAssertEqual(playlist["account_id"] as UID, 1)
            XCTAssertEqual(playlist["name"] as String, "Late show")
            XCTAssertEqual(playlist["kind"] as String, "tv")
            XCTAssertTrue(playlist["station_owned"] as Bool)
            XCTAssertNil(playlist["last_played_at"] as Int64?)
            XCTAssertEqual([playlist["created_at"], playlist["modified_at"]] as [Int64], [ms, ms])
            XCTAssertEqual([playlist["created_by"], playlist["modified_by"]] as [UID?], [1, 1])
            XCTAssertEqual(
                try Int.fetchAll(
                    db, sql: "SELECT weekday FROM station_day WHERE station_id = ? ORDER BY weekday",
                    arguments: [made.id]), [1, 5])
            XCTAssertEqual(
                try UID.fetchAll(
                    db, sql: "SELECT id FROM station_time WHERE station_id = ? ORDER BY from_minute",
                    arguments: [made.id]), rangeIds)
        }
    }

    /// A queued action as `operation method path profile`, its instant and its body.
    private struct QueuedAction: Sendable {
        let queued: String
        let at: Date
        let json: Data
        var body: [String: Any] {
            get throws { try XCTUnwrap(try JSONSerialization.jsonObject(with: json) as? [String: Any]) }
        }
    }

    private func lastAction(_ replica: Replica) async throws -> QueuedAction {
        try await replica.read { db in
            let row = try XCTUnwrap(
                Row.fetchOne(
                    db,
                    sql: "SELECT operation_id, method, path, profile_id, at, body FROM queue.action ORDER BY seq DESC"))
            return QueuedAction(
                queued: "\(row["operation_id"] as String) \(row["method"] as String) \(row["path"] as String) "
                    + "\(row["profile_id"] as UID)", at: ReplicaRows.instant(row["at"]), json: row["body"])
        }
    }

    /// The last queued action's touched rows as `table key1 key2`, in the order given.
    private func touched(_ replica: Replica) async throws -> [String] {
        try await replica.read { db in
            try String.fetchAll(
                db,
                sql: """
                    SELECT table_name || ' ' || key1 || COALESCE(' ' || key2, '') FROM queue.action_touch
                    WHERE action = (SELECT MAX(seq) FROM queue.action) ORDER BY rowid
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
