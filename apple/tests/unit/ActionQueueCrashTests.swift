import Foundation
import GRDB
import HTTPTypes
import OpenAPIRuntime
import RabbitEarsAPI
import Synchronization
import XCTest

@testable import RabbitEarsKit

/// The replica and the queue are two files that commit apart.
final class ActionQueueCrashTests: ActionQueueCase {

    /// Runs `body` on an open replica and queue, then releases both so their files close.
    private func session(_ body: (Replica, ActionQueue) async throws -> Void) async throws {
        let replica = try replica()
        try await body(replica, queue(replica))
    }

    /// Copies `name` aside while every file is closed; `restore` puts it back as it was.
    private func keep(_ name: String) throws -> () throws -> Void {
        let file = fixture.directory.appending(path: name)
        XCTAssertFalse(fixture.exists(URL(filePath: file.path(percentEncoded: false) + "-wal")), "\(name) is closed")
        let copy = fixture.directory.deletingLastPathComponent().appending(path: UUID().uuidString)
        try FileManager.default.copyItem(at: file, to: copy)
        return {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(at: URL(filePath: file.path(percentEncoded: false) + suffix))
            }
            try FileManager.default.moveItem(at: copy, to: file)
        }
    }

    func testAChangeWhoseActionWasLostDropsTheReplicaForASnapshot() async throws {
        try await session { _, _ in }
        let restoreQueue = try keep("queue.sqlite")
        try await session { _, queue in try await watch(queue, item: 40) }
        try await session { replica, _ in XCTAssertFalse(replica.isEmpty, "a replica whose actions are queued stays") }

        try restoreQueue()
        let reopened = try fixture.open()

        XCTAssertTrue(reopened.isEmpty, "a fresh snapshot replaces a change the server will never hear of")
        XCTAssertEqual(try fixture.queuedActions(), [])
    }

    func testAnActionWhoseChangeWasLostIsStillSent() async throws {
        try await session { _, _ in }
        let restoreReplica = try keep(try fixture.current())
        try await session { _, queue in try await watch(queue, item: 40) }

        try restoreReplica()
        let replica = try fixture.open()

        XCTAssertFalse(replica.isEmpty)
        let rows = try await replica.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM watch_state") }
        XCTAssertEqual(rows, 0)
        let flushed = await queue(replica).flush()
        XCTAssertEqual(flushed, .done)
        XCTAssertEqual(batches().map { $0.actions.map(\.path) }, [["/profiles/1/watch-state/40"]])
    }
}
