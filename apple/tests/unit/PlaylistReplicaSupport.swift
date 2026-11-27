import Foundation
import GRDB
import RabbitEarsAPI
import XCTest

@testable import RabbitEarsKit

/// A replica with a queue that never flushes on its own, an engine
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

    func playlists(_ profile: UID = 1, adult: Bool = true) -> PlaylistsModel {
        PlaylistsModel(
            client: client, replica: replica, queue: queue, engine: engine, profileId: profile, adult: adult)
    }

    func collections(_ profile: UID = 1) -> CollectionsModel {
        CollectionsModel(replica: replica, queue: queue, profileId: profile)
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

    /// The last queued action's touched rows as `table k1 k2`, each key part as stored: an id's lowercase text or
    /// an integer.
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
                    + [row["key1"] as DatabaseValue, row["key2"] as DatabaseValue].compactMap { part in
                        String.fromDatabaseValue(part) ?? Int64.fromDatabaseValue(part).map(String.init)
                    })
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

/// Playlist and collection rows of sync schema 1. Instants are Unix ms;
/// a row the owner made carries the owner in created_by and modified_by.
extension Database {
    func playlist(
        _ id: UID, _ name: String, owner: UID = 1, kind: String = "movies", played: Int64? = nil,
        station: Bool = false
    ) throws {
        try execute(
            sql: """
                INSERT INTO playlist(id, account_id, name, kind, last_played_at, created_at, modified_at, created_by,
                    modified_by, station_owned)
                VALUES (?1, ?2, ?3, ?4, ?5, 1000, 2000, ?2, ?2, ?6)
                """, arguments: [id, owner, name, kind, played, station])
    }

    func entry(
        _ id: UID, in playlist: UID, item: UID? = nil, collection: UID? = nil, rank: String, edition: UID? = nil
    ) throws {
        try execute(
            sql: """
                INSERT INTO playlist_entry(id, playlist_id, item_id, collection_id, rank, added_at, edition_id,
                    created_at, modified_at)
                VALUES (?, ?, ?, ?, ?, 3000, ?, 3000, 4000)
                """, arguments: [id, playlist, item, collection, rank, edition])
    }

    func share(_ playlist: UID, with account: UID, _ access: String) throws {
        try execute(
            sql: "INSERT INTO playlist_share(playlist_id, account_id, access, created_at) VALUES (?, ?, ?, 0)",
            arguments: [playlist, account, access])
    }

    func householdShare(_ playlist: UID, with household: UID, _ access: String) throws {
        try execute(
            sql: """
                INSERT INTO playlist_household_share(playlist_id, household_id, access, created_at)
                VALUES (?, ?, ?, 0)
                """,
            arguments: [playlist, household, access])
    }

    /// How another profile shows to those it shares with.
    func card(_ id: UID, _ name: String, household: UID = 8) throws {
        try execute(
            sql: "INSERT INTO account_card(id, name, kind, household_id) VALUES (?, ?, 'adult', ?)",
            arguments: [id, name, household])
    }

    /// A TMDB collection's tmdb_id is 100 times the n of its uid.N id, n below 256.
    func collection(_ id: UID, _ name: String, source: String = "custom", household: UID? = 7) throws {
        try execute(
            sql: """
                INSERT INTO collection(id, source, household_id, tmdb_id, name, overview, created_at, modified_at)
                VALUES (?, ?, ?, ?, ?, ?, 1000, 2000)
                """,
            arguments: [
                id, source, source == "custom" ? household : nil, source == "tmdb" ? Int(id.uuid.uuid.15) * 100 : nil,
                name, source == "tmdb" ? "Three of them." : nil,
            ])
    }

    func collect(_ item: UID, in collection: UID, at position: Int? = nil) throws {
        try execute(
            sql: "INSERT INTO collection_movie(collection_id, item_id, position) VALUES (?, ?, ?)",
            arguments: [collection, item, position])
    }

    /// An edition of the item with one file of `ms`, tagged when `tag` is given; the file has the edition's id.
    func edition(_ id: UID, of item: UID, ms: Int64, tag: String? = nil) throws {
        try execute(sql: "INSERT INTO edition(id, item_id, tag) VALUES (?, ?, ?)", arguments: [id, item, tag])
        try execute(
            sql: """
                INSERT INTO media_file(id, size_bytes, container, duration_ms, bitrate)
                VALUES (?, 1000, 'mkv', ?, 0)
                """,
            arguments: [id, ms])
        try execute(sql: "INSERT INTO edition_file(edition_id, media_file_id) VALUES (?, ?)", arguments: [id, id])
    }

    func music(_ id: UID, _ kind: String, _ title: String, parent: UID? = nil, library: UID = 2) throws {
        try execute(
            sql: """
                INSERT INTO item(id, library_id, parent_id, kind, parsed_title, added_at, explicit)
                VALUES (?, ?, ?, ?, ?, 0, 0)
                """,
            arguments: [id, library, parent, kind, title])
    }

    func station(_ id: UID, of owner: UID, playing playlist: UID) throws {
        try execute(
            sql: "INSERT INTO station(id, account_id, playlist_id, name) VALUES (?, ?, ?, 'Channel')",
            arguments: [id, owner, playlist])
    }

    func cover(_ id: UID, on playlist: UID, item: UID? = nil) throws {
        try execute(
            sql: "INSERT INTO cover(id, playlist_id, item_id, backdrop, created_at) VALUES (?, ?, ?, 0, 0)",
            arguments: [id, playlist, item])
    }
}
