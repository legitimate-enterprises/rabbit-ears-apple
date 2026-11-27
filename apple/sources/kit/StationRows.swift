import Foundation
import GRDB
import RabbitEarsAPI

/// Stations and their programs from the replica, as getStation, listStations
/// and listStationSchedule answer them for one profile. Days and time ranges
/// are read on `calendar`, this device's, where the server reads its own.
enum StationRows {
    /// The stations `profile` may see, by name, of one `kind` or any, or the
    /// one `id`, as the server's profile_station lists them.
    static func stations(
        _ db: Database, profile: Int64, kind: PlaylistKind? = nil, id: Int64? = nil, at now: Date, calendar: Calendar
    ) throws -> [Station] {
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT s.id, s.account_id, s.playlist_id, s.household_id, p.kind, s.name,
                    s.shuffled, s.visibility, s.timing, s.rating, s.created_at, s.updated_at
                \(seen) AND (:kind IS NULL OR p.kind = :kind) ORDER BY s.name COLLATE NOCASE, s.id
                """, arguments: ["profile": profile, "id": id, "kind": kind?.rawValue])
        return try rows.compactMap { try station($0, db, profile: profile, at: now, calendar: calendar) }
    }

    /// The programs overlapping this device's day of `now` that `profile`
    /// may see, by start; nil when it may not see the station.
    static func schedule(
        _ db: Database, station id: Int64, profile: Int64, at now: Date, calendar: Calendar
    ) throws -> [StationProgram]? {
        guard
            try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 \(seen))", arguments: ["profile": profile, "id": id])
                == true
        else { return nil }
        let day = calendar.startOfDay(for: now)
        let next = calendar.date(byAdding: .day, value: 1, to: day) ?? day
        return try programs(
            db, "sp.ends_at > :from AND sp.starts_at < :to ORDER BY sp.starts_at, sp.id",
            ["station": id, "profile": profile, "from": millis(day), "to": millis(next)])
    }

    /// Binds :profile and :id (NULL for every station).
    private static let seen = """
        FROM station s JOIN playlist p ON p.id = s.playlist_id
        WHERE (:id IS NULL OR s.id = :id)
            AND s.id IN (SELECT station_id FROM profile_station WHERE account_id = :profile)
        """

    /// time.Weekday's order, as station_day numbers the days.
    private static let weekdays: [Weekday] = [.sunday, .monday, .tuesday, .wednesday, .thursday, .friday, .saturday]

    private static func station(
        _ row: Row, _ db: Database, profile: Int64, at now: Date, calendar: Calendar
    ) throws -> Station? {
        let id: Int64 = row["id"]
        guard let kind = PlaylistKind(rawValue: row["kind"]),
            let visibility = Components.Schemas.StationVisibility(rawValue: row["visibility"]),
            let timing = Components.Schemas.StationTiming(rawValue: row["timing"])
        else { return nil }
        let days = try Int.fetchAll(
            db, sql: "SELECT weekday FROM station_day WHERE station_id = ? ORDER BY weekday", arguments: [id])
        let times = try Row.fetchAll(
            db,
            sql: """
                SELECT from_minute, to_minute FROM station_time WHERE station_id = ? ORDER BY from_minute, to_minute, id
                """,
            arguments: [id]
        ).map { (from: $0["from_minute"] as Int, to: $0["to_minute"] as Int) }
        // A cover of a title shows while the title is in the station's playlist and the profile may see it.
        let cover = try Int64.fetchOne(
            db,
            sql: """
                SELECT c.id FROM cover c WHERE c.station_id = :id AND (c.item_id IS NULL
                    OR EXISTS (SELECT 1 FROM playlist_entry e WHERE e.playlist_id = :playlist AND e.item_id = c.item_id)
                    AND EXISTS (SELECT 1 FROM profile_item v WHERE v.account_id = :profile AND v.item_id = c.item_id))
                """, arguments: ["id": id, "playlist": row["playlist_id"], "profile": profile])
        let rating: String? = row["rating"]
        return Station(
            id: id, name: row["name"], kind: kind, ownerId: row["account_id"], householdId: row["household_id"],
            playlistId: row["playlist_id"], order: row["shuffled"] ? .random : .playlist, visibility: visibility,
            timing: timing, days: days.compactMap { weekdays.indices.contains($0) ? weekdays[$0] : nil },
            times: times.map { StationTimeRange(from: clock($0.from), to: clock($0.to)) },
            rating: rating?.isEmpty == false ? rating : nil,
            onAir: try onAir(
                db, station: id, profile: profile, open: open(days: days, times: times, at: now, calendar: calendar),
                at: now),
            imageUrl: cover.map { "/api/v1/stations/\(id)/image?v=\($0)" },
            createdAt: ReplicaRows.instant(row["created_at"]), updatedAt: ReplicaRows.instant(row["updated_at"]))
    }

    /// StationService.OnAir: what is on and the ten after it, of what the
    /// profile may see; with nothing on, `open` tells a gap from off schedule.
    private static func onAir(
        _ db: Database, station: Int64, profile: Int64, open: Bool, at now: Date
    ) throws -> StationOnAir {
        let at = millis(now)
        let arguments: StatementArguments = ["station": station, "profile": profile, "at": at]
        let on = try programs(
            db, "sp.starts_at <= :at AND sp.ends_at > :at ORDER BY sp.starts_at DESC LIMIT 1", arguments
        ).first
        let upNext = try programs(db, "sp.starts_at > :at ORDER BY sp.starts_at LIMIT 10", arguments)
        let status: Components.Schemas.StationStatus = on != nil ? .onAir : open ? .betweenPrograms : .offSchedule
        return StationOnAir(
            status: status, now: on,
            positionMs: on.map { at - Int64(($0.startsAt.timeIntervalSince1970 * 1000).rounded()) }, next: upNext.first,
            upNext: upNext)
    }

    /// station.Schedule.Open: inside a window of the days and ranges, where
    /// no days is every day, no ranges all day, and a range ending at or
    /// before its start runs past midnight from the day it starts on.
    static func open(days: [Int], times: [(from: Int, to: Int)], at now: Date, calendar: Calendar) -> Bool {
        if days.isEmpty && times.isEmpty { return true }
        let ranges = times.isEmpty ? [(from: 0, to: 0)] : times
        let today = calendar.dateComponents([.year, .month, .day], from: now)
        func on(_ offset: Int, minute: Int) -> Date? {
            calendar.date(
                from: DateComponents(
                    year: today.year, month: today.month, day: (today.day ?? 1) + offset, minute: minute))
        }
        // Yesterday's ranges may run into today; later days open after now.
        for offset in -1...0 {
            guard let noon = on(offset, minute: 720) else { continue }
            if !days.isEmpty && !days.contains(calendar.component(.weekday, from: noon) - 1) { continue }
            for range in ranges {
                guard let start = on(offset, minute: range.from),
                    let end = on(range.to <= range.from ? offset + 1 : offset, minute: range.to)
                else { continue }
                if start <= now && now < end { return true }
            }
        }
        return false
    }

    /// The station's programs the profile may see that `condition` keeps, in
    /// its order, each filled as a play-order row is. Binds :station and :profile.
    private static func programs(
        _ db: Database, _ condition: String, _ arguments: StatementArguments
    ) throws -> [StationProgram] {
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT sp.item_id, sp.edition_id, sp.starts_at, sp.ends_at, i.kind,
                    CASE WHEN i.kind IN ('season', 'episode') THEN (SELECT CASE WHEN up.kind = 'season'
                        THEN up.parent_id ELSE up.id END FROM item up WHERE up.id = i.parent_id) END AS show_id
                FROM station_program sp JOIN item i ON i.id = sp.item_id
                WHERE sp.station_id = :station
                    AND sp.item_id IN (SELECT item_id FROM profile_item WHERE account_id = :profile) AND \(condition)
                """, arguments: arguments)
        let films = rows.filter { $0["kind"] != "song" }
        let ids = films.map { $0["item_id"] as Int64 } + films.compactMap { $0["show_id"] as Int64? }
        let items = Dictionary(
            try ReplicaRows.items(db, "i.id IN (SELECT value FROM json_each(?))", [json(ids)]).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first })
        let songs = try self.songs(db, rows.filter { $0["kind"] == "song" }.map { $0["item_id"] })
        return try rows.compactMap { row in
            guard let kind = Components.Schemas.PlaylistEntryKind(rawValue: row["kind"]) else { return nil }
            let item: Int64 = row["item_id"]
            let edition: Int64 = row["edition_id"]
            let starts: Int64 = row["starts_at"]
            let ends: Int64 = row["ends_at"]
            var program = StationProgram(
                itemId: item, editionId: edition, editionName: try Editions.name(of: edition, item: item, db),
                kind: kind, startsAt: ReplicaRows.instant(starts), endsAt: ReplicaRows.instant(ends),
                durationMs: ends - starts)
            if kind == .song {
                guard let song = songs[item] else { return nil }
                program.song = song
            } else {
                guard let found = items[item] else { return nil }
                program.item = found
                if let show = row["show_id"] as Int64? { program.show = items[show] }
            }
            return program
        }
    }

    /// Songs by id as the server's music views answer them.
    private static func songs(_ db: Database, _ ids: [Int64]) throws -> [Int64: MusicSong] {
        guard !ids.isEmpty else { return [:] }
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT \(MusicRows.songColumns)
                FROM item s JOIN music_song m ON m.item_id = s.id WHERE s.id IN (SELECT value FROM json_each(?))
                """, arguments: [json(ids)])
        return Dictionary(uniqueKeysWithValues: rows.map { ($0["id"], MusicRows.song($0)) })
    }

    private static func clock(_ minutes: Int) -> String { String(format: "%02d:%02d", minutes / 60, minutes % 60) }

    private static func json(_ ids: [Int64]) -> String { "[\(ids.map(String.init).joined(separator: ","))]" }

    /// Unix milliseconds, as the replica stores instants.
    private static func millis(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded(.down)) }
}
