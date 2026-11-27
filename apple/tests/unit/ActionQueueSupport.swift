import Foundation
import GRDB
import HTTPTypes
import OpenAPIRuntime
import RabbitEarsAPI
import Synchronization
import XCTest

@testable import RabbitEarsKit

/// Ends a debounce each time it is opened.
final class Latch: Sendable {
    private let (stream, continuation) = AsyncStream<Void>.makeStream()

    func wait() async {
        var waiting = stream.makeAsyncIterator()
        _ = await waiting.next()
    }

    func open() { continuation.yield() }
    func close() { continuation.finish() }
}

final class Log<T: Sendable>: Sendable {
    private let items = Mutex<[T]>([])
    func add(_ item: T) { items.withLock { $0.append(item) } }
    var all: [T] { items.withLock { $0 } }
}

/// A queue on a temp replica whose client answers /sync/actions as `answer`
/// does, a debounce that ends only when `gate` opens, and a fixed clock.
class ActionQueueCase: XCTestCase {
    typealias Batch = Components.Schemas.SyncActionBatch

    var fixture: ReplicaFixture!
    var transport: RoutingTransport!
    let gate = Latch()
    let notices = Log<String>()
    let kicks = Log<Void>()
    /// 1800000000.123 s, a time with milliseconds.
    static let now = Date(timeIntervalSince1970: 1_800_000_000.123)

    override func setUp() {
        fixture = ReplicaFixture()
        transport = RoutingTransport()
        transport.respond = { sent in sent.path == "/sync/actions" ? Self.answer(sent) : nil }
    }

    override func tearDown() {
        gate.close()
        fixture.remove()
    }

    func replica() throws -> Replica {
        let replica = try fixture.open()
        if replica.isEmpty { try replica.adopt(fixture.snapshot(version: 5)) }
        return replica
    }

    func queue(_ replica: Replica) -> ActionQueue {
        let gate = gate
        return ActionQueue(
            replica: replica, client: ServerEndpoint.default.client(token: "tok-1", transport: transport),
            notice: { [notices] in notices.add("\($0) \($1 ?? "-")") }, afterFlush: { [kicks] in kicks.add(()) },
            debounce: { await gate.wait() }, now: { Self.now })
    }

    /// Accepts every action of the batch, but rejects those `rejecting`
    /// names with its code and answers only the first `answered`.
    static func answer(
        _ sent: RoutingTransport.Sent, answered: Int = .max, rejecting: [String: String] = [:]
    ) -> (HTTPResponse.Status, String) {
        let batch = Fixtures.decode(sent.body, as: Batch.self)
        // The server answers each id in a UUID's canonical, lowercase form.
        let results = batch.actions.prefix(answered).map { action in
            let id = action.id.lowercased()
            return rejecting[action.operationId].map { #"{"id":"\#(id)","result":"rejected","code":"\#($0)"}"# }
                ?? #"{"id":"\#(id)","result":"accepted"}"#
        }
        return (.ok, #"{"results":[\#(results.joined(separator: ","))]}"#)
    }

    func batches() -> [Batch] {
        transport.sent.filter { $0.path == "/sync/actions" }.map { Fixtures.decode($0.body, as: Batch.self) }
    }

    func queued(_ replica: Replica) async throws -> [String] {
        try await replica.read { try String.fetchAll($0, sql: "SELECT uuid FROM queue.action ORDER BY seq") }
    }

    /// A watched mark for profile UID.n(1) on item `item`, with its row in the replica.
    func watch(_ queue: ActionQueue, item: UID) async throws {
        try await queue.act(
            as: 1, touching: [try .row("watch_state", 1, item)],
            call: { client, at in
                _ = try await client.putWatchState(
                    path: .init(profileId: 1, itemId: item), body: .json(.init(watched: true, at: at)))
            },
            apply: { db, _ in
                try db.execute(sql: "INSERT INTO watch_state VALUES (?, ?, 0)", arguments: [UID.n(1), item])
            })
    }

    func until(_ condition: () async throws -> Bool) async rethrows {
        for _ in 0..<200 {
            if try await condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// The first action's body in the last batch sent, as JSON.
    func firstBody() -> [String: Any]? {
        (transport.json(.post, "/sync/actions")?["actions"] as? [[String: Any]])?.first?["body"] as? [String: Any]
    }
}
