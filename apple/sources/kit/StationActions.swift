import Foundation
import GRDB
import RabbitEarsAPI

extension ActionQueue {
    /// createStation of a station on a playlist of its own, `ownPlaylist`:
    /// the playlist, the station, its days and ranges, as the server writes
    /// them. `input` names the kind, and each range its id. The programs,
    /// loop and rating the server makes as it schedules arrive by sync.
    func createStation(
        _ id: UID, ownPlaylist: UID, _ input: Components.Schemas.StationInput, as profile: UID
    ) async throws {
        var input = input
        (input.id, input.ownPlaylistId, input.playlistId) = (id, ownPlaylist, nil)
        guard let kind = input.kind else { throw AppError.server("A station needs a kind.") }
        let timing = input.timing ?? StationForm.timing(for: kind)
        let (days, times) = Self.schedule(input)
        try await act(
            as: profile,
            touching: try [.row("playlist", ownPlaylist), .row("station", id)]
                + Self.touching(id, days: days, times: times.map(\.id)),
            call: { [input] client, _ in _ = try await client.createStation(body: .json(input)) },
            apply: { [input] db, at in
                let ms = Self.ms(at)
                try db.execute(
                    sql: """
                        INSERT INTO playlist(id, account_id, name, kind, created_at, modified_at, created_by,
                            modified_by, station_owned) VALUES (?1, ?2, ?3, ?4, ?5, ?5, ?2, ?2, 1)
                        """, arguments: [ownPlaylist, profile, input.name, kind.rawValue, ms])
                try db.execute(
                    sql: """
                        INSERT INTO station(id, account_id, playlist_id, name, shuffled, visibility, created_at,
                            modified_at, created_by, modified_by, timing, household_id)
                        VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?7, ?2, ?2, ?8,
                            (SELECT household_id FROM account WHERE id = ?2))
                        """,
                    arguments: [
                        id, profile, ownPlaylist, input.name, input.order == .random,
                        input.visibility?.rawValue ?? Components.Schemas.StationVisibility._private.rawValue, ms,
                        timing.rawValue,
                    ])
                try Self.write(db, id, days: days, times: times)
            })
    }

    /// replaceStation: the station and its days and ranges as the server
    /// rewrites them, `stored` being the station as it stood, whose days
    /// and ranges go. A visibility or timing the input leaves out stays.
    func replaceStation(
        _ id: UID, _ input: Components.Schemas.StationInput, stored: Station?, as profile: UID
    ) async throws {
        var input = input
        (input.id, input.ownPlaylistId) = (nil, nil)
        let (days, times) = Self.schedule(input)
        let oldDays = (stored?.days ?? []).compactMap { StationRows.weekdays.firstIndex(of: $0) }
        let newTimes = times.map(\.id)
        let oldTimes = (stored?.times ?? []).compactMap(\.id).filter { !newTimes.contains($0) }
        try await act(
            as: profile,
            touching: try [.row("station", id)]
                + Self.touching(id, days: Set(days + oldDays).sorted(), times: newTimes + oldTimes),
            call: { [input] client, _ in
                _ = try await client.replaceStation(path: .init(stationId: id), body: .json(input))
            },
            apply: { [input] db, at in
                try db.execute(
                    sql: """
                        UPDATE station SET name = ?, shuffled = ?, visibility = COALESCE(?, visibility),
                            timing = COALESCE(?, timing), modified_at = ?, modified_by = ? WHERE id = ?
                        """,
                    arguments: [
                        input.name, input.order == .random, input.visibility?.rawValue, input.timing?.rawValue,
                        Self.ms(at), profile, id,
                    ])
                try db.execute(sql: "DELETE FROM station_day WHERE station_id = ?", arguments: [id])
                try db.execute(sql: "DELETE FROM station_time WHERE station_id = ?", arguments: [id])
                try Self.write(db, id, days: days, times: times)
            })
    }

    /// deleteStation. Only the station row goes at once: no read reaches its
    /// days, times, programs or own playlist without it, and catch-up
    /// tombstones them once the server has deleted them.
    func deleteStation(_ id: UID, as profileId: UID) async throws {
        try await act(
            as: profileId, touching: [try .row("station", id)],
            call: { client, _ in _ = try await client.deleteStation(path: .init(stationId: id)) },
            apply: { db, _ in try db.execute(sql: "DELETE FROM station WHERE id = ?", arguments: [id]) })
    }

    /// rescheduleStation. Only the server builds a schedule, so nothing
    /// changes here; the new programs arrive by sync.
    func rescheduleStation(_ id: UID, as profileId: UID) async throws {
        try await act(
            as: profileId, touching: [try .row("station", id)],
            call: { client, _ in _ = try await client.rescheduleStation(path: .init(stationId: id)) },
            apply: { _, _ in })
    }

    private struct StationTime {
        let id: UID
        let from: Int
        let to: Int
    }

    /// The input's days as time.Weekday numbers, once each, and its ranges
    /// in minutes; a range without an id is a caller's bug and is left out.
    private static func schedule(
        _ input: Components.Schemas.StationInput
    ) -> (days: [Int], times: [StationTime]) {
        let days = Set((input.days ?? []).compactMap { StationRows.weekdays.firstIndex(of: $0) }).sorted()
        let times = (input.times ?? []).compactMap { range in
            range.id.map {
                StationTime(id: $0, from: StationRows.minutes(range.from), to: StationRows.minutes(range.to))
            }
        }
        return (days, times)
    }

    private static func touching(
        _ station: UID, days: [Int], times: [UID]
    ) throws -> [Components.Schemas.SyncTouched] {
        try days.map { try .row("station_day", station, $0) } + times.map { try .row("station_time", $0) }
    }

    private static func write(_ db: Database, _ station: UID, days: [Int], times: [StationTime]) throws {
        for day in days {
            try db.execute(
                sql: "INSERT INTO station_day(station_id, weekday) VALUES (?, ?)", arguments: [station, day])
        }
        for range in times {
            try db.execute(
                sql: "INSERT INTO station_time(id, station_id, from_minute, to_minute) VALUES (?, ?, ?, ?)",
                arguments: [range.id, station, range.from, range.to])
        }
    }
}
