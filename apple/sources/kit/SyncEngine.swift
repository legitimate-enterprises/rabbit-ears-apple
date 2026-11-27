import Foundation
import GRDB
import Network
import Observation
import OpenAPIRuntime
import RabbitEarsAPI

/// Keeps the replica at the server's version. Every trigger, from a cold
/// start, a return to the foreground, a reconnection or the doorbell, runs
/// the one `catchUp`: it sends the queue, then reads the server's changes
/// as diff pages, or takes a whole snapshot when there is no replica or
/// the server asks for one.
@MainActor
@Observable
public final class SyncEngine {
    public enum Failure: Error, Equatable {
        /// A page that names what the replica lacks, or keys of another shape.
        case malformed(String)
    }

    /// The server does not sync with this build: its ranges leave out this
    /// API version or the replica's schema. The replica stays readable;
    /// nothing is sent or read again by this engine.
    public private(set) var unsupported = false

    /// The longest wait between two tries of a failing catch-up.
    static let longestWait = Duration.seconds(30)

    private let replica: Replica
    private let client: Client
    private let flush: @Sendable () async throws -> Void
    private let signOut: @MainActor () async -> Void
    @ObservationIgnored private var pass: Task<Void, any Error>?
    @ObservationIgnored private var wakers: [UUID: AsyncStream<Void>.Continuation] = [:]

    /// `flush` sends the action queue and throws when it leaves an action
    /// unsent, so a pass never waits on a queue that cannot empty.
    /// `signOut` runs when the server no longer knows the device.
    public init(
        replica: Replica, endpoint: ServerEndpoint, token: String, transport: (any ClientTransport)? = nil,
        flush: @escaping @Sendable () async throws -> Void, signOut: @escaping @MainActor () async -> Void
    ) {
        self.replica = replica
        client = endpoint.client(token: token, transport: transport)
        self.flush = flush
        self.signOut = signOut
    }

    /// One pass: flush, then pull until caught up. A page that meets unsent
    /// actions would overwrite their writes, so it is dropped and the pass
    /// flushes again. Calls made while a pass runs wait for that pass.
    public func catchUp() async throws {
        if let pass { return try await pass.value }
        // Cleared by the pass itself, so no call made after it ends, before its starter resumes, joins it.
        let task = Task {
            defer { pass = nil }
            try await run()
        }
        pass = task
        try await task.value
    }

    /// Replaces the replica with a new snapshot; the queue is kept. Until
    /// one is adopted the old replica is read, and every catch-up takes one.
    public func reset() async throws {
        if !replica.isEmpty { try await replica.write { try $0.execute(sql: "DELETE FROM sync_state") } }
        try await catchUp()
    }

    /// Ends a failure's wait at once, as when the network returns.
    public func wake() {
        for waker in wakers.values { waker.yield() }
    }

    /// Catches up, then again on each ring of the server's doorbell, until
    /// cancelled or unsupported. A failure is tried again after a wait that
    /// doubles up to 30 seconds, cut short by `wake` or the network coming
    /// back. A refusal stops; one saying the server no longer knows the
    /// device signs it out first. `device_locked` is tried again instead:
    /// a pass begun at Who's watching brings it after a profile is picked,
    /// and a device locked again leaves the views that follow.
    public func follow(sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }) async {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor in self?.wake() }
        }
        monitor.start(queue: .main)
        defer { monitor.cancel() }
        var wait = Duration.seconds(1)
        while !Task.isCancelled {
            do {
                try await catchUp()
                if unsupported { return }
                wait = .seconds(1)
                while try await !rang() {}
            } catch {
                if Task.isCancelled { return }
                if let api = APIError.from(error), api.status < 500, api.code != .deviceLocked {
                    if api.code == .unauthorized { await signOut() }
                    return
                }
                await pause(wait, sleep)
                wait = min(wait * 2, Self.longestWait)
            }
        }
    }

    private func run() async throws {
        while !unsupported {
            try await flush()
            if try await pull() { return }
        }
    }

    /// True once caught up or unsupported; false when a page met unsent actions.
    private func pull() async throws -> Bool {
        while true {
            let held = try await held()
            let page = try await client.getSyncChanges(
                query: .init(schema: Int(held.schema), since: held.version, cursor: held.cursor)
            ).ok.body.json
            guard page.mode != .unsupported, Self.supports(page.ranges, schema: held.schema) else {
                unsupported = true
                return true
            }
            if page.mode == .snapshot {
                let body = try await client.getSyncSnapshot(query: .init(schema: Int(held.schema)))
                    .ok.body.applicationVnd_sqlite3
                try await Self.adopt(body, into: replica)
                continue
            }
            guard let version = page.version else { throw Failure.malformed("a diff without a version") }
            guard try await replica.write({ try Self.apply(page, version: version, in: $0) }) else { return false }
            if page.cursor == nil { return true }
        }
    }

    /// The schema to ask in, and the version and cursor the replica holds;
    /// no version once reset, and none without a replica.
    private struct Held: Sendable {
        var schema = Replica.schemas.upperBound
        var version: Int64?
        var cursor: String?
    }

    private func held() async throws -> Held {
        guard !replica.isEmpty else { return Held() }
        return try await replica.read { db in
            let state = try Row.fetchOne(db, sql: "SELECT version, cursor FROM sync_state")
            return Held(
                schema: try Int64.fetchOne(db, sql: "SELECT schema FROM replica_meta") ?? Replica.schemas.upperBound,
                version: state?["version"], cursor: state?["cursor"])
        }
    }

    private func rang() async throws -> Bool {
        guard let version = try await held().version else { return true }
        return try await client.waitSyncVersion(query: .init(after: version)).ok.body.json.changed
    }

    private func pause(_ wait: Duration, _ sleep: @escaping @Sendable (Duration) async -> Void) async {
        let (woken, waker) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        wakers[id] = waker
        defer { wakers[id] = nil }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await sleep(wait) }
            group.addTask { for await _ in woken { return } }
            await group.next()
            group.cancelAll()
        }
    }

    private static func supports(_ ranges: Components.Schemas.SyncRanges, schema: Int64) -> Bool {
        let api = numbers(ActionQueue.apiVersion)
        return Int64(ranges.schemaMin) <= schema && schema <= Int64(ranges.schemaMax)
            && !api.lexicographicallyPrecedes(numbers(ranges.apiMin))
            && !numbers(ranges.apiMax).lexicographicallyPrecedes(api)
    }

    private static func numbers(_ version: String) -> [Int] {
        version.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
    }

    /// Streams a snapshot into the replica's directory and adopts it, its
    /// search index built; a failed download leaves no file behind.
    @concurrent
    nonisolated private static func adopt(_ body: HTTPBody, into replica: Replica) async throws {
        let file = replica.partFile()
        do {
            FileManager.default.createFile(atPath: file.path(percentEncoded: false), contents: nil)
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            for try await chunk in body { try handle.write(contentsOf: chunk) }
        } catch {
            try? FileManager.default.removeItem(at: file)
            throw error
        }
        try replica.adopt(file, prepare: ReplicaSearch.build)
    }

    /// Applies a diff page whole with the sync state it leads to, or
    /// nothing: false, writing nothing, while actions wait in the queue.
    nonisolated private static func apply(
        _ page: Components.Schemas.SyncChanges, version: Int64, in db: Database
    ) throws -> Bool {
        guard try Int.fetchOne(db, sql: "SELECT count(*) FROM queue.action") == 0 else { return false }
        var changed: [String: [DatabaseValue]] = [:]
        for table in page.tables ?? [] {
            let (columns, key) = try shape(table.name, in: db)
            guard Set(table.columns).isSubset(of: columns.keys), let first = table.columns.firstIndex(of: key[0]),
                Set(key).isSubset(of: table.columns)
            else { throw Failure.malformed("columns \(table.columns) of \(table.name)") }
            let declared = table.columns.compactMap { columns[$0] }
            let rest = table.columns.filter { !key.contains($0) }
            let update =
                rest.isEmpty
                ? "NOTHING"
                : "UPDATE SET " + rest.map { "\(quote($0)) = excluded.\(quote($0))" }.joined(separator: ", ")
            let statement = try db.cachedStatement(
                sql: "INSERT INTO \(quote(table.name)) (\(table.columns.map(quote).joined(separator: ", "))) "
                    + "VALUES (\(Array(repeating: "?", count: table.columns.count).joined(separator: ", "))) "
                    + "ON CONFLICT (\(key.map(quote).joined(separator: ", "))) DO \(update)")
            for row in table.rows {
                guard row.count == table.columns.count else { throw Failure.malformed("a row of \(table.name)") }
                let values = try zip(row, declared).map { try $0.databaseValue(declared: $1) }
                try statement.execute(arguments: StatementArguments(values))
                changed[table.name, default: []].append(values[first])
            }
        }
        for tombstones in page.tombstones ?? [] {
            let (columns, key) = try shape(tombstones.table, in: db)
            let declared = key.compactMap { columns[$0] }
            let statement = try db.cachedStatement(
                sql: "DELETE FROM \(quote(tombstones.table)) WHERE "
                    + key.map { "\(quote($0)) = ?" }.joined(separator: " AND "))
            for parts in tombstones.keys {
                guard parts.count == key.count else { throw Failure.malformed("a key of \(tombstones.table)") }
                let values = try zip(parts, declared).map { try $0.databaseValue(declared: $1) }
                try statement.execute(arguments: StatementArguments(values))
                changed[tombstones.table, default: []].append(values[0])
            }
        }
        try ReplicaSearch.update(in: db, changed: changed)
        try db.execute(sql: "UPDATE sync_state SET version = ?, cursor = ?", arguments: [version, page.cursor])
        return true
    }

    /// A synced table's columns with their declared types, and its primary
    /// key in key order, as the replica file declares them. Views, the
    /// queue's tables and the replica's own bookkeeping have no key here, so
    /// a page cannot write them.
    nonisolated private static func shape(_ table: String, in db: Database) throws -> ([String: String], [String]) {
        let columns = try Row.fetchAll(
            db, sql: "SELECT name, pk, type FROM pragma_table_info(?, 'main')", arguments: [table]
        ).map { (name: $0["name"] as String, pk: $0["pk"] as Int, type: $0["type"] as String) }
        let key = columns.filter { $0.pk > 0 }.sorted { $0.pk < $1.pk }.map(\.name)
        guard !key.isEmpty else { throw Failure.malformed("table \(table)") }
        return (Dictionary(uniqueKeysWithValues: columns.map { ($0.name, $0.type) }), key)
    }

    nonisolated private static func quote(_ name: String) -> String {
        "\"\(name.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}

extension Components.Schemas.SyncScalar {
    /// The SQLite value of a cell of a column declared `declared`. Every
    /// BLOB column holds an id, which arrives as its string and is stored
    /// as its 16 bytes: a text id there would match no join.
    func databaseValue(declared: String) throws -> DatabaseValue {
        guard declared.caseInsensitiveCompare("BLOB") == .orderedSame else { return try databaseValue() }
        switch value {
        case nil: return .null
        case let text as String:
            guard let id = UID(text) else { throw SyncEngine.Failure.malformed("an id \(text)") }
            return id.databaseValue
        default: throw SyncEngine.Failure.malformed("an id that is not a string")
        }
    }

    /// The SQLite value of a JSON cell: an integer, a real, text or null.
    /// The decoder tries Bool before Int, so a boolean arrives as one and is refused.
    func databaseValue() throws -> DatabaseValue {
        switch value {
        case nil: .null
        case let number as Int: Int64(number).databaseValue
        case let number as Double: number.databaseValue
        case let text as String: text.databaseValue
        default: throw SyncEngine.Failure.malformed("a cell that is not a scalar")
        }
    }
}
