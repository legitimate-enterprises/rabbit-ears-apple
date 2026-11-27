import Foundation
import GRDB
import HTTPTypes
import OpenAPIRuntime
import RabbitEarsAPI

/// Writes this device makes while it may be offline: each changes the
/// replica at once and is queued as the generated call that makes it on
/// the server, sent later through replaySyncActions. A rejected action is
/// not undone here; the server marks the rows it touched, and catch-up
/// brings them back.
public actor ActionQueue {
    public enum Flush: Sendable, Equatable {
        /// Every action sent was answered and the queue is empty.
        case done
        /// Actions remain, to send again on reconnect.
        case offline
        /// The server replays no batch from this build; the queue is kept for a newer one.
        case unsupported
        /// The server refused the device itself; the queue is kept.
        case refused(APIError)
    }

    public enum Failure: Error, Equatable {
        /// A call or touched keys replaySyncActions would refuse.
        case unsendable(String)
    }

    /// The spec's info.version this build was generated from; ActionQueueTests holds it to openapi.yaml.
    static let apiVersion = "0.21.0"
    /// SyncActionBatch's maxItems.
    static let batchLimit = 100
    /// SyncAction's touched maxItems; ActionRecorderTests holds it to openapi.yaml.
    static let touchedLimit = 5000
    /// The largest request body replaySyncActions takes, an `x-upload` operation's.
    static let bodyLimit = 16 << 20

    private let replica: Replica
    private let client: Client
    /// The real client's encoding with no middlewares and a transport that sends nothing.
    private let recorder = Client.connect(to: ServerEndpoint.default.baseURL, token: nil, transport: ActionRecorder())
    /// The same, refusing a body over `bodyLimit`.
    private let measurer = Client.connect(
        to: ServerEndpoint.default.baseURL, token: nil, transport: ActionRecorder(limit: bodyLimit))
    private let notice: @Sendable (_ operationId: String, _ code: String?) -> Void
    private let afterFlush: @Sendable () -> Void
    private let debounce: @Sendable () async -> Void
    private let now: @Sendable () -> Date

    private var pending: Task<Void, Never>?
    private var draining: Task<Flush, Never>?
    /// Counts flushes asked, so one asked while a drain runs gets a pass that starts after it.
    private var asked = 0
    private var unsupported = false

    /// `notice` hears each rejection; `afterFlush` runs after a flush that
    /// removed actions, to start a catch-up. `debounce` is the wait between
    /// an action and the flush it schedules.
    public init(
        replica: Replica, client: Client,
        notice: @escaping @Sendable (_ operationId: String, _ code: String?) -> Void = { _, _ in },
        afterFlush: @escaping @Sendable () -> Void = {},
        debounce: @escaping @Sendable () async -> Void = { try? await Task.sleep(for: .seconds(1)) },
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.replica = replica
        self.client = client
        self.notice = notice
        self.afterFlush = afterFlush
        self.debounce = debounce
        self.now = now
    }

    /// Records the one call `call` makes on the client it is given, then in
    /// one write runs `apply` and queues the call with `touched`, the
    /// replica rows `apply` writes or deletes, by primary key. Both get the
    /// action's instant, which an operation ordering writes by time also
    /// takes in its body or query. When `apply` throws nothing is queued.
    /// An action touching more than `touchedLimit` rows cannot be queued: it
    /// is made on the server at once, after what is queued, and `apply` is
    /// not run; a catch-up brings the rows it wrote.
    public func act(
        as profileId: UID, touching touched: [Components.Schemas.SyncTouched],
        call: @Sendable (Client, Date) async throws -> Void,
        apply: @escaping @Sendable (Database, Date) throws -> Void
    ) async throws {
        let ms = Int64((now().timeIntervalSince1970 * 1000).rounded(.down))
        let at = Date(timeIntervalSince1970: Double(ms) / 1000)
        let recorded = try await record { try await call($0, at) }
        guard touched.allSatisfy({ (1...3).contains($0.key.count) }) else { throw Failure.unsendable("touched keys") }
        guard touched.count <= Self.touchedLimit else {
            await flush()
            try await call(client, at)
            afterFlush()
            return
        }
        let uuid = UUID().uuidString.lowercased()
        try await replica.write { db in
            try apply(db, at)
            try db.execute(
                sql: "INSERT INTO queue.action(uuid, operation_id, method, path, body, profile_id, at) "
                    + "VALUES (?, ?, ?, ?, ?, ?, ?)",
                arguments: [
                    uuid, recorded.operationID, recorded.method, recorded.path, recorded.body, profileId, ms,
                ])
            let seq = db.lastInsertedRowID
            for row in touched {
                let key = try row.key.map { try $0.databaseValue() } + [.null, .null]
                try db.execute(
                    sql: "INSERT INTO queue.action_touch(action, table_name, key1, key2, key3) VALUES (?, ?, ?, ?, ?)",
                    arguments: [seq, row.table, key[0], key[1], key[2]])
            }
            try db.execute(sql: "CREATE TABLE IF NOT EXISTS main.\(Replica.appliedTable) (seq INTEGER NOT NULL)")
            try db.execute(sql: "DELETE FROM main.\(Replica.appliedTable)")
            try db.execute(sql: "INSERT INTO main.\(Replica.appliedTable) VALUES (?)", arguments: [seq])
        }
        schedule()
    }

    /// Sends the queue in order until it is empty or a batch goes
    /// unanswered. A flush asked while one runs joins it, and that one goes
    /// on to send what was queued before the second was asked.
    @discardableResult
    public func flush() async -> Flush {
        asked += 1
        let task = draining ?? Task { await drain() }
        draining = task
        return await task.value
    }

    /// The first action of a burst starts the wait; the rest ride on it.
    private func schedule() {
        guard pending == nil else { return }
        pending = Task { [weak self, debounce] in
            await debounce()
            await self?.debounced()
        }
    }

    private func debounced() async {
        pending = nil
        await flush()
    }

    private func drain() async -> Flush {
        var served = 0
        var removed = false
        var outcome = Flush.done
        while served < asked, outcome == .done {
            served = asked
            outcome = await sendAll(removed: &removed)
        }
        draining = nil
        if removed { afterFlush() }
        return outcome
    }

    /// A batch refused whole is sent again one action at a time, so only an
    /// action refused alone is dropped and none blocks the queue for ever.
    private func sendAll(removed: inout Bool) async -> Flush {
        var limit = Self.batchLimit
        while !unsupported {
            do {
                var batch = try await replica.read { [limit] in try Self.batch($0, limit: limit) }
                while batch.count > 1, await oversized(batch) { batch.removeLast(batch.count / 2) }
                guard let first = batch.first else { return .done }
                let results: [Components.Schemas.SyncActionResult]
                do {
                    results = try await client.replaySyncActions(
                        body: .json(.init(apiVersion: Self.apiVersion, actions: batch))
                    ).ok.body.json.results
                } catch let error where APIError.from(error)?.status == 400 {
                    guard batch.count == 1 else {
                        limit = 1
                        continue
                    }
                    try await remove([first.seq])
                    removed = true
                    notice(first.operationId, APIError.from(error)?.code.rawValue)
                    continue
                }
                if results.contains(where: { $0.code == "unsupported_version" }) {
                    unsupported = true
                    break
                }
                // Ids are UUIDs, which the server answers in their canonical lowercase form.
                let sent = Dictionary(uniqueKeysWithValues: batch.map { ($0.id.lowercased(), $0) })
                let answered = results.compactMap { result in
                    sent[result.id.lowercased()].map { (action: $0, result: result) }
                }
                try await remove(answered.map(\.action.seq))
                removed = removed || !answered.isEmpty
                for (action, result) in answered
                where result.result == .rejected && !Self.madeBefore(action.operationId, result.code) {
                    notice(action.operationId, result.code)
                }
                // The server stops a batch at its first failure; the rest go again later.
                if answered.count < batch.count { return .offline }
            } catch {
                if let refusal = APIError.from(error), refusal.code == .unauthorized { return .refused(refusal) }
                return .offline
            }
        }
        return .unsupported
    }

    /// Whether the batch's request body, as the client encodes it, is over `bodyLimit`.
    private func oversized(_ batch: [Components.Schemas.SyncAction]) async -> Bool {
        do {
            _ = try await measurer.replaySyncActions(body: .json(.init(apiVersion: Self.apiVersion, actions: batch)))
        } catch let error as ClientError {
            return !(error.underlyingError is ActionRecorder.Recorded)
        } catch {}
        return true
    }

    /// A create under a client id answered `conflict` met its own row: the
    /// server made it, lost the answer and was sent it again. Its rows come by sync.
    private static func madeBefore(_ operationId: String, _ code: String?) -> Bool {
        code == "conflict"
            && ["createPlaylist", "addPlaylistEntry", "addPlaylistEntries", "createCollection", "createStation"]
                .contains(operationId)
    }

    private func remove(_ seqs: [Int64]) async throws {
        try await replica.write { db in
            try db.execute(literal: "DELETE FROM queue.action_touch WHERE action IN \(seqs)")
            try db.execute(literal: "DELETE FROM queue.action WHERE seq IN \(seqs)")
        }
    }

    private static func batch(_ db: Database, limit: Int) throws -> [Components.Schemas.SyncAction] {
        let rows = try Row.fetchAll(
            db,
            sql: "SELECT seq, uuid, operation_id, method, path, body, profile_id, at FROM queue.action "
                + "ORDER BY seq LIMIT ?", arguments: [limit])
        let seqs = rows.map { $0["seq"] as Int64 }
        var touched: [Int64: [Components.Schemas.SyncTouched]] = [:]
        let touches: SQL =
            "SELECT action, table_name, key1, key2, key3 FROM queue.action_touch WHERE action IN \(seqs) ORDER BY rowid"
        for row in try SQLRequest<Row>(literal: touches).fetchAll(db) {
            var key: [Components.Schemas.SyncScalar] = []
            for part in [row["key1"], row["key2"], row["key3"]] as [DatabaseValue] {
                switch part.storage {
                case .string(let text): key.append(try .init(unvalidatedValue: text))
                case .int64(let number): key.append(try .init(unvalidatedValue: Int(number)))
                case .null: break
                default: throw Failure.unsendable("a key part of \(row["table_name"] as String)")
                }
            }
            touched[row["action"], default: []].append(.init(table: row["table_name"], key: key))
        }
        return try rows.map { row in
            let seq: Int64 = row["seq"]
            guard let method = Components.Schemas.SyncAction.MethodPayload(rawValue: row["method"]) else {
                throw Failure.unsendable(row["method"])
            }
            let body = try (row["body"] as Data?).map(Self.body)
            return .init(
                id: row["uuid"], seq: seq, operationId: row["operation_id"], method: method, path: row["path"],
                body: body, actingProfileId: row["profile_id"],
                at: Date(timeIntervalSince1970: Double(row["at"] as Int64) / 1000), touched: touched[seq] ?? [])
        }
    }

    /// The stored JSON as the container decoding it would give, parsed once:
    /// that decoding throws for each type it tries on each value.
    static func body(_ data: Data) throws -> OpenAPIValueContainer {
        try OpenAPIValueContainer(unvalidatedValue: value(JSONSerialization.jsonObject(with: data)))
    }

    /// A number as the container's decoding takes it: a Bool, else an Int where exact, else a Double.
    private static func value(_ object: Any) -> (any Sendable)? {
        switch object {
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue }
            if !CFNumberIsFloatType(number) { return number.intValue }
            return Int(exactly: number.doubleValue) ?? number.doubleValue
        case let text as String: return text
        case let array as [Any]: return array.map(value)
        case let object as [String: Any]: return object.mapValues(value)
        default: return nil
        }
    }

    private func record(_ call: (Client) async throws -> Void) async throws -> ActionRecorder.Recorded {
        do {
            try await call(recorder)
        } catch let error as ClientError {
            guard let recorded = error.underlyingError as? ActionRecorder.Recorded else { throw error }
            guard Components.Schemas.SyncAction.MethodPayload(rawValue: recorded.method) != nil else {
                throw Failure.unsendable(recorded.method)
            }
            return recorded
        }
        throw Failure.unsendable("no call made")
    }
}

/// Keeps the request a generated call makes and fails the call with it,
/// so nothing is sent. The path is relative to the API's base, query included.
struct ActionRecorder: ClientTransport {
    struct Recorded: Error {
        let method: String
        let path: String
        let body: Data?
        let operationID: String
    }

    /// A longer body fails the call with the runtime's own error.
    var limit = 1 << 20

    func send(
        _ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String
    ) async throws -> (HTTPResponse, HTTPBody?) {
        var bytes: Data?
        if let body { bytes = try await Data(collecting: body, upTo: limit) }
        throw Recorded(
            method: request.method.rawValue, path: request.path ?? "/", body: bytes, operationID: operationID)
    }
}

extension Components.Schemas.SyncTouched {
    /// A replica row by its id key parts, in primary-key order.
    static func row(_ table: String, _ key: UID...) throws -> Self {
        .init(table: table, key: try key.map { try .init(unvalidatedValue: $0.description) })
    }

    /// A row keyed by an id and an integer, as station_day's (station_id, weekday).
    static func row(_ table: String, _ id: UID, _ part: Int) throws -> Self {
        .init(table: table, key: [try .init(unvalidatedValue: id.description), try .init(unvalidatedValue: part)])
    }
}
