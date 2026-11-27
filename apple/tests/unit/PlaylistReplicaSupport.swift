import Foundation
import GRDB
import RabbitEarsAPI
import XCTest

@testable import RabbitEarsKit

/// A v1 replica with a queue that never flushes on its own, an engine
/// whose catch-ups reach `transport`, and the server's answers there.
@MainActor
final class SyncedReplica {
    let fixture = ReplicaFixture()
    let transport = RoutingTransport()
    let gate = Latch()
    let replica: Replica
    let queue: ActionQueue
    let engine: SyncEngine
    var client: Client { ServerEndpoint.default.client(token: "t", transport: transport) }

    /// With `sample`, over the server's seeded test fixture.
    init(sample: Bool = false, _ rows: (Database) throws -> Void = { _ in }) throws {
        replica = try fixture.v1(sample: sample, rows)
        let gate = gate
        queue = ActionQueue(
            replica: replica, client: ServerEndpoint.default.client(token: "t", transport: transport),
            debounce: { await gate.wait() })
        engine = SyncEngine(
            replica: replica, endpoint: .default, token: "t", transport: transport, flush: {}, signOut: {})
    }

    func playlists(_ profile: Int64 = 1, adult: Bool = true) -> PlaylistsModel {
        PlaylistsModel(
            client: client, replica: replica, queue: queue, engine: engine, profileId: profile, adult: adult)
    }

    func collections(_ profile: Int64 = 1) -> CollectionsModel {
        CollectionsModel(client: client, replica: replica, queue: queue, engine: engine, profileId: profile)
    }

    /// Each queued action as `operationId METHOD path`, oldest first.
    func queued() throws -> [String] {
        try actions {
            try Row.fetchAll($0, sql: "SELECT operation_id, method, path FROM action ORDER BY seq")
                .map { "\($0["operation_id"] as String) \($0["method"] as String) \($0["path"] as String)" }
        }
    }

    /// The last queued action's body as JSON.
    func lastBody() throws -> [String: Any]? {
        let body = try actions {
            try Data.fetchOne($0, sql: "SELECT body FROM action ORDER BY seq DESC LIMIT 1")
        }
        return body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    /// The last queued action's touched rows as `table k1 k2`.
    func lastTouched() throws -> [String] {
        try actions {
            try Row.fetchAll(
                $0,
                sql: """
                    SELECT table_name, key1, key2 FROM action_touch
                    WHERE action = (SELECT MAX(seq) FROM action) ORDER BY rowid
                    """
            ).map { row in
                ([row["table_name"] as String]
                    + [row["key1"], row["key2"]].compactMap { ($0 as Int64?).map(String.init) })
                    .joined(separator: " ")
            }
        }
    }

    /// Reads the queue's own file, as the app finds it on its next launch.
    private func actions<T>(_ body: (Database) throws -> T) throws -> T {
        try DatabaseQueue(path: fixture.queue.path(percentEncoded: false)).read(body)
    }

    func read<T: Sendable>(_ sql: String) async throws -> [T] where T: DatabaseValueConvertible {
        try await replica.read { try T.fetchAll($0, sql: sql) }
    }

    /// Whether a catch-up asked the server for changes.
    var caughtUp: Bool { transport.paths(.get).contains("/sync/changes") }

    func remove() {
        gate.close()
        fixture.remove()
    }
}

/// Playlist and collection rows of sync schema 1. Instants are Unix ms.
extension Database {
    func playlist(
        _ id: Int64, _ name: String, owner: Int64 = 1, kind: String = "movies", played: Int64? = nil,
        station: Bool = false
    ) throws {
        try execute(
            sql: "INSERT INTO playlist VALUES (?, ?, ?, ?, ?, 1000, 2000, ?)",
            arguments: [id, owner, name, kind, played, station])
    }

    func entry(
        _ id: Int64, in playlist: Int64, item: Int64? = nil, collection: Int64? = nil, rank: String,
        edition: Int64? = nil
    ) throws {
        try execute(
            sql: "INSERT INTO playlist_entry VALUES (?, ?, ?, ?, ?, 3000, ?)",
            arguments: [id, playlist, item, collection, rank, edition])
    }

    func share(_ playlist: Int64, with account: Int64, _ access: String) throws {
        try execute(sql: "INSERT INTO playlist_share VALUES (?, ?, ?, 0)", arguments: [playlist, account, access])
    }

    func householdShare(_ playlist: Int64, with household: Int64, _ access: String) throws {
        try execute(
            sql: "INSERT INTO playlist_household_share VALUES (?, ?, ?, 0)", arguments: [playlist, household, access])
    }

    /// How another profile shows to those it shares with.
    func card(_ id: Int64, _ name: String, household: Int64 = 8) throws {
        try execute(
            sql: "INSERT INTO account_card(id, name, kind, household_id) VALUES (?, ?, 'adult', ?)",
            arguments: [id, name, household])
    }

    func collection(_ id: Int64, _ name: String, source: String = "custom", household: Int64? = 7) throws {
        try execute(
            sql: "INSERT INTO collection VALUES (?, ?, ?, ?, ?, ?, 1000, 2000)",
            arguments: [
                id, source, source == "custom" ? household : nil, source == "tmdb" ? id * 100 : nil, name,
                source == "tmdb" ? "Three of them." : nil,
            ])
    }

    func collect(_ item: Int64, in collection: Int64, at position: Int? = nil) throws {
        try execute(sql: "INSERT INTO collection_movie VALUES (?, ?, ?)", arguments: [collection, item, position])
    }

    /// An edition of the item with one file of `ms`, tagged when `tag` is given.
    func edition(_ id: Int64, of item: Int64, ms: Int64, tag: String? = nil) throws {
        try execute(sql: "INSERT INTO edition VALUES (?, ?, ?, NULL)", arguments: [id, item, tag])
        try execute(sql: "INSERT INTO media_file VALUES (?, 1000, 'mkv', ?, 0, NULL)", arguments: [id, ms])
        try execute(sql: "INSERT INTO edition_file VALUES (?, ?)", arguments: [id, id])
    }

    func music(_ id: Int64, _ kind: String, _ title: String, parent: Int64? = nil, library: Int64 = 2) throws {
        try execute(
            sql: """
                INSERT INTO item(id, library_id, parent_id, kind, parsed_title, added_at, explicit)
                VALUES (?, ?, ?, ?, ?, 0, 0)
                """,
            arguments: [id, library, parent, kind, title])
    }

    func station(_ id: Int64, of owner: Int64, playing playlist: Int64) throws {
        try execute(
            sql: "INSERT INTO station(id, account_id, playlist_id, name) VALUES (?, ?, ?, 'Channel')",
            arguments: [id, owner, playlist])
    }

    func cover(_ id: Int64, on playlist: Int64, item: Int64? = nil) throws {
        try execute(
            sql: "INSERT INTO cover VALUES (?, ?, NULL, ?, 0, 0)", arguments: [id, playlist, item])
    }
}
