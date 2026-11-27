import Foundation
import GRDB
import Synchronization

/// This device's copy of what the server lets its household see: a SQLite
/// file the server builds and sends whole, replaced whole by the next
/// snapshot. The actions not yet sent live in a file apart, attached to
/// every connection as `queue`, so they outlive each replacement.
public final class Replica: Sendable {
    /// What a view reads again when its tables change.
    public enum Group: Sendable, CaseIterable { case library, watched, playlists, stations, household }

    public enum Failure: Error, Equatable {
        /// No replica yet; one comes with a snapshot.
        case empty
        case damaged
        /// A sync schema this build does not read.
        case unsupported(schema: Int64)
    }

    /// The sync schemas this build reads.
    public static let schemas: ClosedRange<Int64> = 1...1

    /// The replica's tables by the group a change to them names; a table
    /// the replica lacks is passed over.
    static let groups: [Group: [String]] = [
        .library: [
            "library", "item", "item_metadata", "item_genre", "genre", "person", "credit", "item_keyword", "edition",
            "edition_file", "media_file", "track", "chapter", "occasion", "occasion_keyword", "occasion_item",
            "occasion_exclusion", "occasion_phrase", "server_info", "collection", "collection_movie", "account_allow",
            "holiday", "holiday_date", "holiday_color",
        ],
        .watched: ["watch_state"],
        .playlists: ["playlist", "playlist_entry", "playlist_share", "playlist_household_share", "cover"],
        .stations: ["station", "station_day", "station_time", "station_program", "station_loop", "cover"],
        .household: ["household", "account", "account_card", "household_member", "adult_link", "profile_offer"],
    ]

    /// Foreign keys are off on every connection, so an action's touched
    /// keys are deleted with it by hand. `at` is a UTC instant in Unix
    /// milliseconds; key parts keep the type each was stored with.
    static let queueSchema = """
        CREATE TABLE IF NOT EXISTS action (
            seq INTEGER PRIMARY KEY AUTOINCREMENT,
            uuid TEXT NOT NULL UNIQUE,
            operation_id TEXT NOT NULL,
            method TEXT NOT NULL,
            path TEXT NOT NULL,
            body BLOB,
            profile_id INTEGER NOT NULL,
            at INTEGER NOT NULL
        );
        CREATE TABLE IF NOT EXISTS action_touch (
            action INTEGER NOT NULL,
            table_name TEXT NOT NULL,
            key1 NOT NULL,
            key2,
            key3
        );
        CREATE INDEX IF NOT EXISTS action_touch_action ON action_touch(action);
        CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value);
        """

    /// The replica's record of the last action applied to it, written in
    /// the action's transaction. The replica and the queue commit apart, so
    /// a crash can keep a change whose action the queue lost; such a
    /// replica fails its check at open, for a fresh snapshot. An action
    /// kept without its change is sent, and catch-up brings the change.
    static let appliedTable = "action_applied"

    /// In the app's own container, which backups leave out; tvOS keeps
    /// nothing outside Caches, which the system may clear while the app is
    /// not running.
    public static var defaultDirectory: URL {
        #if os(tvOS)
            URL.cachesDirectory.appending(path: "Replica")
        #else
            URL.applicationSupportDirectory.appending(path: "Replica")
        #endif
    }

    public let directory: URL
    /// The group of each change committed, and every group on each new replica.
    public let changes: AsyncStream<Group>
    private let changed: AsyncStream<Group>.Continuation
    private let state = Mutex(State())

    private struct State {
        var pool: DatabasePool?
        /// The file `pool` reads, as `current` names it.
        var name: String?
        var observations: [AnyDatabaseCancellable] = []
        var lostActions = false
    }

    private var pointer: URL { directory.appending(path: "current") }
    private var queueFile: URL { directory.appending(path: "queue.sqlite") }

    public init(directory: URL = Replica.defaultDirectory) {
        self.directory = directory
        (changes, changed) = AsyncStream.makeStream()
    }

    public var isEmpty: Bool { state.withLock { $0.pool == nil } }

    /// Moves `group` in `changes` with nothing committed, for what time alone changes.
    public func elapsed(_ group: Group) { changed.yield(group) }

    /// The queue was damaged at open and replaced by an empty one.
    public var lostActions: Bool { state.withLock { $0.lostActions } }

    /// A file to download a snapshot into; one left behind is deleted at the next open.
    public func partFile() -> URL { directory.appending(path: "\(UUID().uuidString).part") }

    /// Opens the replica `current` names. Every other file but the queue
    /// is deleted, and so is a replica that is missing, unreadable or fails
    /// its check, leaving the store empty until a snapshot.
    public func open() throws {
        try makeDirectory()
        var lost = false
        do {
            try openQueue()
        } catch let error where Self.isCorrupt(error) {
            remove { $0.hasPrefix(queueFile.lastPathComponent) }
            try openQueue()
            lost = true
        }
        let named = try? String(contentsOf: pointer, encoding: .utf8)
        let pool = named.flatMap { try? checkedPool(named: $0) }
        let name = pool == nil ? nil : named
        let kept = [queueFile.lastPathComponent] + (name.map { [$0] } ?? [])
        remove { file in !kept.contains(where: file.hasPrefix) && (name == nil || file != pointer.lastPathComponent) }
        _ = install(pool, name)
        state.withLock { $0.lostActions = lost }
    }

    /// Makes the snapshot at `file` current once it passes its check and
    /// `prepare` has run inside it; the file is taken either way. A
    /// snapshot that fails leaves the current replica as it was.
    public func adopt(_ file: URL, prepare: (Database) throws -> Void = { _ in }) throws {
        defer { try? FileManager.default.removeItem(at: file) }
        let path = file.path(percentEncoded: false)
        var readOnly = Configuration()
        readOnly.readonly = true
        let version = try DatabaseQueue(path: path, configuration: readOnly).read(Self.check)
        try DatabaseQueue(path: path).write { db in
            try db.execute(sql: "CREATE TABLE sync_state (version INTEGER NOT NULL, cursor TEXT)")
            try db.execute(sql: "INSERT INTO sync_state VALUES (?, NULL)", arguments: [version])
            try prepare(db)
        }
        try makeDirectory()
        try openQueue()
        // Unique, so a snapshot at the current version never lands on the open file.
        let name = "replica-\(version)-\(UUID().uuidString).sqlite"
        try FileManager.default.moveItem(at: file, to: directory.appending(path: name))
        var pool: DatabasePool?
        do {
            pool = try self.pool(at: directory.appending(path: name))
            // The rename and this write are the commit: a crash before it keeps the old replica.
            try Data(name.utf8).write(to: pointer, options: .atomic)
        } catch {
            try? pool?.close()
            remove { $0.hasPrefix(name) }
            throw error
        }
        if let old = install(pool, name) { remove { $0.hasPrefix(old) } }
        for group in Group.allCases { changed.yield(group) }
    }

    /// Off the caller's thread. A read that meets a swap runs again on the
    /// new replica, so none sees a closed one.
    public func read<T: Sendable>(_ body: @escaping @Sendable (Database) throws -> T) async throws -> T {
        while true {
            let pool = try current()
            do {
                return try await pool.read(body)
            } catch {
                guard state.withLock({ $0.pool }) !== pool else { throw error }
            }
        }
    }

    /// The one writer, for applying the server's changes and this device's actions alike.
    public func write<T: Sendable>(_ body: @escaping @Sendable (Database) throws -> T) async throws -> T {
        try await current().write(body)
    }

    /// A value kept in the queue's `meta` by key, which outlives every
    /// snapshot, for reading before there is one; nil when none or unreadable.
    public func kept(_ key: String) -> Data? {
        var configuration = Configuration()
        configuration.readonly = true
        configuration.busyMode = .timeout(2)
        let queue = try? DatabaseQueue(path: queueFile.path(percentEncoded: false), configuration: configuration)
        return try? queue?.read { try Data.fetchOne($0, sql: "SELECT value FROM meta WHERE key = ?", arguments: [key]) }
    }

    /// Best effort, once opened.
    public func keep(_ value: Data, as key: String) {
        var configuration = Configuration()
        configuration.busyMode = .timeout(2)
        let queue = try? DatabaseQueue(path: queueFile.path(percentEncoded: false), configuration: configuration)
        try? queue?.write {
            try $0.execute(
                sql: "INSERT INTO meta VALUES (?, ?) ON CONFLICT (key) DO UPDATE SET value = excluded.value",
                arguments: [key, value])
        }
    }

    /// Signed out, or on another server: the replica and the unsent actions go.
    public func wipe() throws {
        _ = install(nil, nil)
        guard FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)) else { return }
        try FileManager.default.removeItem(at: directory)
    }

    private func current() throws -> DatabasePool {
        guard let pool = state.withLock({ $0.pool }) else { throw Failure.empty }
        return pool
    }

    /// Makes `pool` current and closes the one it replaces, once the reads
    /// and the write in flight on it end. Returns the replaced file's name.
    private func install(_ pool: DatabasePool?, _ name: String?) -> String? {
        let observations = pool.map(observe) ?? []
        let old = state.withLock { state in
            defer { (state.pool, state.name, state.observations) = (pool, name, observations) }
            return (pool: state.pool, name: state.name, observations: state.observations)
        }
        for observation in old.observations { observation.cancel() }
        // A pool that fails to close still reads its files after they are deleted.
        try? old.pool?.close()
        return old.name
    }

    private func observe(_ pool: DatabasePool) -> [AnyDatabaseCancellable] {
        Self.groups.map { group, tables in
            DatabaseRegionObservation(tracking: tables.map { Table($0) })
                .start(in: pool, onError: { _ in }, onChange: { [changed] _ in changed.yield(group) })
        }
    }

    private func checkedPool(named name: String) throws -> DatabasePool {
        let file = directory.appending(path: name)
        guard FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) else { throw Failure.empty }
        let pool = try pool(at: file)
        do {
            _ = try pool.read(Self.check)
            try pool.read(Self.checkApplied)
        } catch {
            try? pool.close()
            throw error
        }
        return pool
    }

    private func pool(at file: URL) throws -> DatabasePool {
        var configuration = Configuration()
        // The projection leaves out rows that the rows it carries point at.
        configuration.foreignKeysEnabled = false
        // Every connection to the queue, the kept values' among them, waits out another's write.
        configuration.busyMode = .timeout(2)
        let queue = queueFile.path(percentEncoded: false)
        configuration.prepareDatabase { db in
            try db.execute(sql: "ATTACH DATABASE ? AS queue", arguments: [queue])
        }
        return try DatabasePool(path: file.path(percentEncoded: false), configuration: configuration)
    }

    /// Creates the queue's tables where missing; throws when the file is damaged.
    private func openQueue() throws {
        var configuration = Configuration()
        configuration.journalMode = .wal
        configuration.busyMode = .timeout(2)
        try DatabaseQueue(path: queueFile.path(percentEncoded: false), configuration: configuration).write { db in
            guard try String.fetchOne(db, sql: "PRAGMA quick_check") == "ok" else { throw Failure.damaged }
            try db.execute(sql: Self.queueSchema)
        }
    }

    /// The replica's version, when it is sound and in a schema this build reads.
    private static func check(_ db: Database) throws -> Int64 {
        guard try String.fetchOne(db, sql: "PRAGMA main.quick_check") == "ok",
            let meta = try Row.fetchOne(
                db,
                sql: "SELECT schema, version FROM replica_meta "
                    + "WHERE typeof(schema) = 'integer' AND typeof(version) = 'integer'")
        else { throw Failure.damaged }
        let schema: Int64 = meta["schema"]
        guard schemas.contains(schema) else { throw Failure.unsupported(schema: schema) }
        return meta["version"]
    }

    /// Seqs are never reused, so a replica that applied one past the last
    /// the queue issued holds a change the queue lost.
    private static func checkApplied(_ db: Database) throws {
        guard try db.tableExists(appliedTable, in: "main") else { return }
        let applied = try Int64.fetchOne(db, sql: "SELECT max(seq) FROM main.\(appliedTable)") ?? 0
        let issued = try Int64.fetchOne(db, sql: "SELECT seq FROM queue.sqlite_sequence WHERE name = 'action'") ?? 0
        guard applied <= issued else { throw Failure.damaged }
    }

    private static func isCorrupt(_ error: any Error) -> Bool {
        let code = (error as? DatabaseError)?.resultCode
        return error as? Failure == .damaged || code == .SQLITE_CORRUPT || code == .SQLITE_NOTADB
    }

    private func makeDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var url = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }

    private func remove(where doomed: (String) -> Bool) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))) ?? []
        for name in names where doomed(name) {
            try? FileManager.default.removeItem(at: directory.appending(path: name))
        }
    }
}
