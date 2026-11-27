import Foundation
import GRDB
import XCTest

@testable import RabbitEarsKit

extension Database {
    /// `account` as a profile of `household`, its member there, with `color` as the server stores it.
    func member(
        _ id: Int64, _ name: String, kind: String = "adult", filter: String = "ratings", household: Int64 = 7,
        pin: Bool = false, color: String? = nil
    ) throws {
        try account(id, name, kind: kind, filter: filter)
        try execute(
            sql: "UPDATE account SET household_id = ?, has_pin = ?, color = ? WHERE id = ?",
            arguments: [household, pin, color, id])
        try execute(
            sql: "INSERT INTO account_card(id, name, kind, color, household_id, pending) VALUES (?, ?, ?, ?, ?, 0)",
            arguments: [id, name, kind, color, household])
        try execute(sql: "INSERT INTO household_member VALUES (?, ?)", arguments: [household, id])
    }
}

extension SyncedApp {
    /// The queued actions, in order, as operation, method and path.
    func queued() async throws -> [String] {
        try await XCTUnwrap(model.sync).replica.read {
            try String.fetchAll(
                $0, sql: "SELECT operation_id || ' ' || method || ' ' || path FROM queue.action ORDER BY seq")
        }
    }

    /// Every touched key of the queued actions, as `table key1/key2`.
    func touched() async throws -> [String] {
        try await XCTUnwrap(model.sync).replica.read {
            try String.fetchAll(
                $0,
                sql: """
                    SELECT table_name || ' ' || key1 || COALESCE('/' || key2, '') FROM queue.action_touch
                    ORDER BY action, rowid
                    """)
        }
    }

    func value<T: DatabaseValueConvertible & Sendable>(_ sql: String) async throws -> T? {
        try await XCTUnwrap(model.sync).replica.read { try T.fetchOne($0, sql: sql) }
    }

    /// The bodies the queue sent, as JSON, in order.
    func sentBodies() -> [[String: Any]] {
        routes.sent.filter { $0.path == "/sync/actions" }.flatMap { sent -> [[String: Any]] in
            let json = (try? JSONSerialization.jsonObject(with: Data(sent.body.utf8))) as? [String: Any]
            return ((json?["actions"] as? [[String: Any]]) ?? []).compactMap { $0["body"] as? [String: Any] }
        }
    }

    func offline() { routes.failure = URLError(.notConnectedToInternet) }
}
