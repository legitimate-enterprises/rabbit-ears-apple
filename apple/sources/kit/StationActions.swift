import Foundation
import GRDB
import RabbitEarsAPI

extension ActionQueue {
    /// deleteStation. Only the station row goes at once: no read reaches its
    /// days, times, programs or own playlist without it, and catch-up
    /// tombstones them once the server has deleted them.
    func deleteStation(_ id: Int64, as profileId: Int64) async throws {
        try await act(
            as: profileId, touching: [.init(table: "station", key: [try .init(unvalidatedValue: Int(id))])],
            call: { client, _ in _ = try await client.deleteStation(path: .init(stationId: id)) },
            apply: { db, _ in try db.execute(sql: "DELETE FROM station WHERE id = ?", arguments: [id]) })
    }

    /// rescheduleStation. Only the server builds a schedule, so nothing
    /// changes here; the new programs arrive by sync.
    func rescheduleStation(_ id: Int64, as profileId: Int64) async throws {
        try await act(
            as: profileId, touching: [try .row("station", id)],
            call: { client, _ in _ = try await client.rescheduleStation(path: .init(stationId: id)) },
            apply: { _, _ in })
    }
}
