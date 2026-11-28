import Foundation
import GRDB
import RabbitEarsAPI
import XCTest

@testable import RabbitEarsKit

/// A replica directory of its own, and snapshots shaped as the server
/// ships them: tables with primary keys and no foreign keys, a view, an
/// index and the one-row `replica_meta`.
struct ReplicaFixture {
    let directory = FileManager.default.temporaryDirectory.appending(path: "Replica \(UUID().uuidString)")
    let downloads = FileManager.default.temporaryDirectory.appending(path: "Snapshots \(UUID().uuidString)")
    /// XCTest keeps every test case, and so each replica one holds, for the whole run; `remove` closes them.
    private let opened = Log<Opened>()

    private struct Opened: Sendable {
        weak var replica: Replica?
    }

    var queue: URL { directory.appending(path: "queue.sqlite") }
    var pointer: URL { directory.appending(path: "current") }

    func open() throws -> Replica {
        let replica = Replica(directory: directory)
        opened.add(Opened(replica: replica))
        try replica.open()
        return replica
    }

    /// A downloaded snapshot at `version` of household UID.n(7) whose items are `titles`, ids from UID.n(1).
    func snapshot(version: Int64, schema: Int64 = 1, titles: [String] = ["Antenna"]) throws -> URL {
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        let file = downloads.appending(path: "\(UUID().uuidString).part")
        try DatabaseQueue(path: file.path(percentEncoded: false)).write { db in
            try db.execute(
                sql: """
                    CREATE TABLE replica_meta(schema INTEGER NOT NULL, version INTEGER NOT NULL,
                        household_id BLOB NOT NULL);
                    CREATE TABLE item(id BLOB PRIMARY KEY, title TEXT NOT NULL);
                    CREATE TABLE watch_state(account_id BLOB NOT NULL, item_id BLOB NOT NULL,
                        position_ms INTEGER NOT NULL, PRIMARY KEY (account_id, item_id));
                    CREATE TABLE playlist(id BLOB PRIMARY KEY, account_id BLOB NOT NULL, name TEXT NOT NULL);
                    CREATE VIEW item_shown AS SELECT * FROM item;
                    CREATE INDEX item_title ON item(title);
                    """)
            try db.execute(sql: "INSERT INTO replica_meta VALUES (?, ?, ?)", arguments: [schema, version, UID.n(7)])
            for (index, title) in titles.enumerated() {
                try db.execute(sql: "INSERT INTO item VALUES (?, ?)", arguments: [UID.n(index + 1), title])
            }
        }
        return file
    }

    /// A replica of "Antenna" and one queued action, left closed as when
    /// the app ends, so damage to its files is not masked by open ones.
    func closedWithAnAction() async throws {
        try await withAnAction()
        for name in [try current(), "queue.sqlite"] {
            XCTAssertFalse(exists(directory.appending(path: "\(name)-wal")), "\(name) is closed")
        }
    }

    /// The replica is released on return, which closes its files.
    private func withAnAction() async throws {
        let replica = try open()
        try replica.adopt(snapshot(version: 5, titles: ["Antenna"]))
        try await replica.write { try $0.execute(sql: Self.enqueue("a")) }
    }

    /// The name `current` holds.
    func current() throws -> String { try String(contentsOf: pointer, encoding: .utf8) }

    func names() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false)).sorted()
    }

    /// What open would delete: anything but the pointer, the file it names and the queue.
    func strays() throws -> [String] {
        let current = try? current()
        return try names().filter {
            $0 != "current" && !$0.hasPrefix("queue.sqlite") && !(current.map($0.hasPrefix) ?? false)
        }
    }

    func exists(_ file: URL) -> Bool { FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) }

    func queuedActions() throws -> [String] {
        try DatabaseQueue(path: queue.path(percentEncoded: false)).read {
            try String.fetchAll($0, sql: "SELECT uuid FROM action ORDER BY seq")
        }
    }

    func remove() {
        for opened in opened.all { try? opened.replica?.wipe() }
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.removeItem(at: downloads)
    }

    /// A replica in sync schema 1, as adopted from a snapshot: its search
    /// index built and `rows` written first. Without `sample` it holds only
    /// `server_info`, whose settings show TMDB's metadata alone, as `item`
    /// writes it; with it, the server's seeded test fixture.
    func v1(sample: Bool = false, _ rows: (Database) throws -> Void = { _ in }) throws -> Replica {
        let replica = try open()
        try replica.adopt(v1File(sample: sample, rows), prepare: ReplicaSearch.build)
        return replica
    }

    /// The snapshot `v1` adopts, at version 1, as the server serves it.
    func v1File(sample: Bool = false, _ rows: (Database) throws -> Void = { _ in }) throws -> URL {
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        let file = downloads.appending(path: "\(UUID().uuidString).part")
        try DatabaseQueue(path: file.path(percentEncoded: false)).write { db in
            try db.execute(sql: ReplicaSchema.v1)
            try db.execute(
                sql: sample
                    ? ReplicaSchema.sample
                    : """
                    INSERT INTO replica_meta VALUES (1, 1, \(sqlID(7)));
                    INSERT INTO server_info VALUES (1, 'Home', 'remote', 'only');
                    """)
            try rows(db)
        }
        return file
    }

    static func enqueue(_ uuid: String) -> String {
        """
        INSERT INTO queue.action(uuid, operation_id, method, path, body, profile_id, at)
        VALUES ('\(uuid)', 'putWatchState', 'PUT', '/profiles/\(UID.n(1))/watch-state/\(UID.n(5))', x'7b7d',
            \(sqlID(1)), 1800000000000)
        """
    }

    /// SQLite no longer knows the file as a database.
    static func breakHeader(_ file: URL) throws { try overwrite(file, at: 0, count: 100) }

    /// The header stands; the second page, a table's root, is garbage.
    static func breakPage(_ file: URL) throws { try overwrite(file, at: 4096, count: 4096) }

    private static func overwrite(_ file: URL, at offset: UInt64, count: Int) throws {
        let handle = try FileHandle(forWritingTo: file)
        try handle.seek(toOffset: offset)
        try handle.write(contentsOf: Data(repeating: 0xA5, count: count))
        try handle.close()
    }
}

/// Rows of sync schema 1, written as `Fixtures` writes the server's answers
/// for them. Instants are ISO 8601 text, stored as Unix milliseconds.
extension Database {
    /// A catalog item as `Fixtures.item` describes it, its metadata in a
    /// matched TMDB row. `kids` is the item's own override; without it the
    /// rating decides, as on the server.
    func item(
        _ id: UID, _ kind: String, _ title: String, parent: UID? = nil, season: Int? = nil,
        episode: Int? = nil, added: String = "2026-01-01T00:00:00Z", runtime: Int? = nil, rating: String? = nil,
        year: Int? = nil, genres: [(UID, String)] = [], kids: Bool? = nil, library: UID = 1
    ) throws {
        try execute(
            sql: """
                INSERT INTO item(id, library_id, parent_id, kind, parsed_title, parsed_year, season_number,
                    episode_number, added_at, kids_content) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [id, library, parent, kind, title, year, season, episode, Self.ms(added), kids])
        try execute(
            sql: """
                INSERT INTO item_metadata(item_id, source, provider, status, runtime_minutes, content_rating)
                VALUES (?, 'remote', 'tmdb', 'matched', ?, ?)
                """, arguments: [id, runtime, rating])
        for (genre, name) in genres {
            try execute(sql: "INSERT OR IGNORE INTO genre(id, name) VALUES (?, ?)", arguments: [genre, name])
            try execute(
                sql: "INSERT INTO item_genre(item_id, genre_id, source) VALUES (?, ?, 'remote')",
                arguments: [id, genre])
        }
    }

    /// A watch state as `Fixtures.watch` describes it, for `profile`.
    func watch(
        _ item: UID, for profile: UID, position: Int64 = 0, watched: Bool = false, played: String? = nil,
        edition: UID? = nil
    ) throws {
        try execute(
            sql: """
                INSERT INTO watch_state(account_id, item_id, position_ms, watched, play_count, last_played_at,
                    changed_at, edition_id) VALUES (?, ?, ?, ?, 0, ?, ?, ?)
                """,
            arguments: [
                profile, item, position, watched, played.map(Self.ms), Self.ms("2026-01-01T00:00:00Z"), edition,
            ])
    }

    /// A profile of household UID.n(7); a kid's ceilings are the server's ratings, as PG or TV-Y7.
    func account(
        _ id: UID, _ name: String, kind: String = "adult", hidingKids: Bool = false, filter: String = "ratings",
        movies: String? = nil, tv: String? = nil
    ) throws {
        try execute(
            sql: """
                INSERT INTO account(id, kind, name, is_admin, household_id, filter_mode, movie_ceiling, tv_ceiling,
                    created_at, modified_at, hide_kids_content, no_autoplay, has_pin, pending)
                VALUES (?, ?, ?, 0, ?, ?, ?, ?, 0, 0, ?, 0, 0, 0)
                """, arguments: [id, kind, name, UID.n(7), filter, movies, tv, hidingKids])
    }

    /// TMDB's `/<poster>.jpg` and `/<backdrop>.jpg` as an item's art, which `profile_art` names as
    /// `ArtworkTests.address(poster)` and `ArtworkTests.address(backdrop, store: "w1280")`.
    func art(_ item: UID, poster: String?, backdrop: String? = nil) throws {
        try execute(
            sql: """
                INSERT INTO item_metadata(item_id, source, provider, status, poster_path, backdrop_path)
                VALUES (?, 'remote', 'tmdb', 'matched', ?, ?) ON CONFLICT (item_id, source) DO UPDATE
                SET provider = 'tmdb', poster_path = excluded.poster_path, backdrop_path = excluded.backdrop_path
                """, arguments: [item, poster.map { "/\($0).jpg" }, backdrop.map { "/\($0).jpg" }])
    }

    func allow(_ item: UID, for profile: UID) throws {
        try execute(sql: "INSERT INTO account_allow(account_id, item_id) VALUES (?, ?)", arguments: [profile, item])
    }

    func library(_ id: UID, _ kind: String) throws {
        try execute(
            sql: "INSERT INTO library(id, name, kind) VALUES (?, ?, ?)", arguments: [id, kind.capitalized, kind])
    }

    static func ms(_ instant: String) -> Int64 {
        Int64((ISO8601DateFormatter().date(from: instant)?.timeIntervalSince1970 ?? 0) * 1000)
    }
}

extension XCTestCase {
    /// A v1 replica holding `items` and `watch`, as `Fixtures` writes the
    /// server's answers for them, of an adult `profile`; removed after the test.
    func replica(_ items: [String], watch: [String] = [], profile: UID) throws -> Replica {
        let fixture = ReplicaFixture()
        addTeardownBlock { fixture.remove() }
        return try fixture.v1 { db in
            try db.account(profile, "Avery")
            for item in items { try db.insert(Fixtures.decode(item, as: Item.self)) }
            for state in watch { try db.insert(Fixtures.decode(state, as: WatchState.self), for: profile) }
        }
    }
}

extension Database {
    /// The rows the server projects for an item it answers as `item`, its metadata TMDB's.
    func insert(_ item: Item) throws {
        try execute(
            sql: """
                INSERT INTO item(id, library_id, parent_id, kind, parsed_title, parsed_year, season_number,
                    episode_number, added_at, kids_content) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                item.id, item.libraryId, item.parentId, item.kind.rawValue, item.parsedTitle, item.parsedYear,
                item.seasonNumber, item.episodeNumber, Int64(item.addedAt.timeIntervalSince1970 * 1000),
                item.kidsContentOverride,
            ])
        if let metadata = item.metadata {
            try execute(
                sql: """
                    INSERT INTO item_metadata(item_id, source, provider, provider_id, status, title, overview,
                        release_date, runtime_minutes, content_rating, poster_path, backdrop_path)
                    VALUES (?, 'remote', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    item.id, metadata.provider?.rawValue, metadata.providerId, metadata.status.rawValue, metadata.title,
                    metadata.overview, metadata.releaseDate, metadata.runtimeMinutes, metadata.contentRating,
                    metadata.posterPath, metadata.backdropPath,
                ])
        }
        for genre in item.genres ?? [] {
            try execute(
                sql: "INSERT OR IGNORE INTO genre(id, name, tmdb_id) VALUES (?, ?, ?)",
                arguments: [genre.id, genre.name, genre.tmdbId])
            try execute(
                sql: "INSERT INTO item_genre(item_id, genre_id, source) VALUES (?, ?, 'remote')",
                arguments: [item.id, genre.id])
        }
    }

    func insert(_ state: WatchState, for profile: UID) throws {
        let ms = { (date: Date) in Int64(date.timeIntervalSince1970 * 1000) }
        try execute(
            sql: """
                INSERT INTO watch_state(account_id, item_id, position_ms, watched, play_count, last_played_at,
                    changed_at, edition_id) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                profile, state.itemId, state.positionMs, state.watched, state.playCount, state.lastPlayedAt.map(ms),
                ms(state.changedAt), state.editionId,
            ])
    }
}
