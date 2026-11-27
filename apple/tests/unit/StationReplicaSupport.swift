import Foundation
import GRDB
import RabbitEarsAPI
import XCTest

@testable import RabbitEarsKit

/// Station rows of sync schema 1, instants as ISO 8601 text.
extension Database {
    /// A station of `owner`'s on its own playlist, of the same id plus 100,
    /// of `kind`; `days` are time.Weekday numbers, Sunday 0, and `times`
    /// minutes of the day. Its household is the owner's, as the server
    /// ships it, or `household` for an owner the replica lacks.
    func station(
        _ id: Int64, _ name: String, owner: Int64 = 1, kind: String = "movies", visibility: String = "household",
        timing: String = "hour", shuffled: Bool = false, rating: String? = nil, days: [Int] = [],
        times: [(Int, Int)] = [], created: String = "2026-01-01T00:00:00Z", updated: String = "2026-01-02T00:00:00Z",
        household: Int64? = nil
    ) throws {
        try execute(
            sql: "INSERT INTO playlist VALUES (?, ?, ?, ?, NULL, 0, 0, 1)", arguments: [id + 100, owner, name, kind])
        try execute(
            sql: """
                INSERT INTO station VALUES (?, ?, ?, ?, ?, ?, ?, 0, ?, ?, ?,
                    COALESCE(?, (SELECT household_id FROM account WHERE id = ?2), 0))
                """,
            arguments: [
                id, owner, id + 100, name, shuffled, visibility, rating, Self.ms(created), Self.ms(updated), timing,
                household,
            ])
        for day in days { try execute(sql: "INSERT INTO station_day VALUES (?, ?)", arguments: [id, day]) }
        for (index, range) in times.enumerated() {
            try execute(
                sql: "INSERT INTO station_time VALUES (?, ?, ?, ?)",
                arguments: [id * 10 + Int64(index), id, range.0, range.1])
        }
    }

    func program(_ id: Int64, station: Int64, item: Int64, edition: Int64? = nil, starts: String, ends: String) throws {
        try execute(
            sql: "INSERT INTO station_program VALUES (?, ?, ?, ?, NULL, 0, 0, ?, ?)",
            arguments: [id, station, item, edition ?? item * 10, Self.ms(starts), Self.ms(ends)])
    }

    /// An entry of the station's playlist, which its kid filter and cover read.
    func entry(_ id: Int64, station: Int64, item: Int64) throws {
        try execute(
            sql: "INSERT INTO playlist_entry(id, playlist_id, item_id, rank, added_at) VALUES (?, ?, ?, ?, 0)",
            arguments: [id, station + 100, item, "a\(id)"])
    }

    /// An edition of `item` with one file, long `runtime` or, without it, as long as the file.
    func edition(
        _ id: Int64, item: Int64, tag: String? = nil, runtime: Int64? = nil, fileMs: Int64 = 6_000_000
    ) throws {
        try execute(sql: "INSERT INTO edition VALUES (?, ?, ?, ?)", arguments: [id, item, tag, runtime])
        try execute(
            sql: "INSERT INTO media_file VALUES (?, 1000, 'mkv', ?, 0, NULL)", arguments: [id + 5000, fileMs])
        try execute(sql: "INSERT INTO edition_file VALUES (?, ?)", arguments: [id, id + 5000])
    }

    func cover(_ id: Int64, station: Int64, item: Int64?) throws {
        try execute(
            sql: "INSERT INTO cover(id, station_id, item_id, backdrop, created_at) VALUES (?, ?, ?, 0, 0)",
            arguments: [id, station, item])
    }
}

/// A calendar fixed to UTC and US English, so days and times read the same on any Mac.
let utcCalendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    calendar.locale = Locale(identifier: "en_US")
    return calendar
}()

extension XCTestCase {
    /// A model over `replica`, as profile `profile` sees it at `now`, its queue held until the test ends.
    @MainActor
    func stationsModel(
        _ replica: Replica, profile: Int64 = 1, transport: RoutingTransport = RoutingTransport(),
        now: String = "2026-11-15T15:12:00Z", calendar: Calendar = utcCalendar,
        sleep: @escaping @MainActor (Date) async throws -> Void = { _ in try await Task.sleep(for: .seconds(3600)) }
    ) -> StationsModel {
        let client = ServerEndpoint.default.client(token: "t", transport: transport)
        let instant = ISO8601DateFormatter().date(from: now)!
        let engine = SyncEngine(
            replica: replica, endpoint: .default, token: "t", transport: transport, flush: {}, signOut: {})
        let queue = ActionQueue(
            replica: replica, client: client, debounce: { try? await Task.sleep(for: .seconds(3600)) })
        return StationsModel(
            client: client, replica: replica, queue: queue, engine: engine, profileId: profile, now: { instant },
            calendar: calendar, sleep: sleep)
    }
}

extension XCTestCase {
    /// A replica, removed after the test, in which Avery (1) finds The Big
    /// Screen (5) between programs, Salt and Ember next at 16:00 as
    /// `Fixtures.salt` has it, and Kitchen Radio (6) with nothing on.
    func tunerReplica() throws -> Replica {
        let fixture = ReplicaFixture()
        addTeardownBlock { fixture.remove() }
        return try fixture.v1 { db in
            try db.account(1, "Avery")
            try db.item(20, "movie", "The Lantern Keeper")
            try db.item(21, "movie", "Salt and Ember")
            try db.station(5, "The Big Screen")
            try db.station(6, "Kitchen Radio", kind: "music", timing: "continuous")
            try db.program(20, station: 5, item: 20, starts: "2026-11-15T14:00:00Z", ends: "2026-11-15T15:52:00Z")
            try db.program(21, station: 5, item: 21, starts: "2026-11-15T16:00:00Z", ends: "2026-11-15T18:18:00Z")
        }
    }

    /// A tuner for Avery over `replica` whose clock reads 15:55, between The Lantern Keeper and Salt and Ember.
    @MainActor
    func stationTuner(
        client: Client, replica: Replica, station: Station,
        sleep: @escaping @MainActor (Date) async throws -> Void = { _ in try await Task.sleep(for: .seconds(3600)) }
    ) -> StationTuner {
        let now = ISO8601DateFormatter().date(from: "2026-11-15T15:55:00Z")!
        return StationTuner(
            client: client, replica: replica, profileId: 1, station: station, now: { now }, calendar: utcCalendar,
            sleep: sleep)
    }
}

extension XCTestCase {
    /// At 15:12 UTC on Sunday 15 November 2026. Avery (1) and Robin (2) are
    /// adults of household 7, Kit (3) a kid to PG and TV-Y7, Jo (4) hides
    /// kids' content, Remy (5) an adult of household 9. The Big Screen (5)
    /// is Avery's, shuffled, on Mondays and Fridays, with The Lantern
    /// Keeper on; Robin's Creature Double (7) is private and Attic Tunes (8)
    /// plays a song; Remy's Neighbors (9) is his household's, Zebra (10) the
    /// server's, off schedule; Avery's Yard (11) is continuous and empty.
    func stationHousehold(_ rows: @escaping (Database) throws -> Void = { _ in }) throws -> Replica {
        let fixture = ReplicaFixture()
        addTeardownBlock { fixture.remove() }
        return try fixture.v1 { db in
            try db.account(1, "Avery")
            try db.account(2, "Robin")
            try db.account(3, "Kit", kind: "kid", movies: "PG", tv: "TV-Y7")
            try db.account(4, "Jo", hidingKids: true)
            try db.account(5, "Remy")
            try db.execute(sql: "UPDATE account SET household_id = 9 WHERE id = 5")
            try db.item(20, "movie", "The Lantern Keeper", rating: "PG-13")
            try db.item(21, "movie", "Salt and Ember", rating: "PG")
            try db.item(22, "movie", "Moon Pie", rating: "G")
            try db.item(90, "show", "Pocket Dragons", rating: "TV-Y7")
            try db.item(91, "season", "Season 2", parent: 90, season: 2)
            try db.item(23, "episode", "Hatchlings", parent: 91, season: 2, episode: 5)
            try db.library(3, "music")
            try db.item(40, "artist", "Radiohead", library: 3)
            try db.item(50, "album", "In Rainbows", parent: 40, year: 2007, library: 3)
            try db.item(30, "song", "Paper Lanterns", parent: 50, library: 3)
            try db.execute(sql: "UPDATE item SET disc_number = 1, track_number = 4, explicit = 0 WHERE id = 30")
            try db.edition(300, item: 30, fileMs: 240_000)
            try db.execute(
                sql: "INSERT INTO track(id, media_file_id, stream_index, kind, codec) VALUES (?, ?, 0, 'audio', ?)",
                arguments: [1, 5300, "flac"])
            try db.station(
                5, "The Big Screen", shuffled: true, rating: "PG-13", days: [5, 1], times: [(1320, 120), (600, 660)])
            try db.entry(1, station: 5, item: 20)
            try db.entry(2, station: 5, item: 21)
            try db.cover(77, station: 5, item: nil)
            try db.program(19, station: 5, item: 21, starts: "2026-11-15T12:00:00Z", ends: "2026-11-15T13:52:00Z")
            try db.program(20, station: 5, item: 20, starts: "2026-11-15T14:00:00Z", ends: "2026-11-15T15:52:00Z")
            try db.program(21, station: 5, item: 21, starts: "2026-11-15T16:00:00Z", ends: "2026-11-15T18:18:00Z")
            try db.program(23, station: 5, item: 23, starts: "2026-11-15T18:30:00Z", ends: "2026-11-15T19:00:00Z")
            try db.program(22, station: 5, item: 22, starts: "2026-11-15T19:00:00Z", ends: "2026-11-15T20:30:00Z")
            try db.station(7, "creature Double", owner: 2, visibility: "private")
            try db.station(8, "attic Tunes", owner: 2, kind: "music", timing: "continuous")
            try db.program(30, station: 8, item: 30, starts: "2026-11-15T15:10:00Z", ends: "2026-11-15T15:14:00Z")
            try db.station(9, "Neighbors", owner: 5)
            try db.station(10, "Zebra", owner: 5, kind: "tv", visibility: "server", times: [(1200, 1260)])
            try db.station(11, "Yard", visibility: "private")
            try rows(db)
        }
    }
}
