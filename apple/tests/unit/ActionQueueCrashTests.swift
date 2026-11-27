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

    func testAQueueOfIntegerProfileIdsLosesItsActionsAndKeepsItsValues() async throws {
        try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: true)
        try await DatabaseQueue(path: fixture.queue.path(percentEncoded: false)).write { db in
            try db.execute(
                sql: """
                    CREATE TABLE action (seq INTEGER PRIMARY KEY AUTOINCREMENT, uuid TEXT NOT NULL UNIQUE,
                        operation_id TEXT NOT NULL, method TEXT NOT NULL, path TEXT NOT NULL, body BLOB,
                        profile_id INTEGER NOT NULL, at INTEGER NOT NULL);
                    CREATE TABLE action_touch (action INTEGER NOT NULL, table_name TEXT NOT NULL, key1 NOT NULL,
                        key2, key3);
                    CREATE TABLE meta (key TEXT PRIMARY KEY, value);
                    INSERT INTO action(uuid, operation_id, method, path, profile_id, at)
                        VALUES ('old', 'putWatchState', 'PUT', '/profiles/1/watch-state/5', 1, 0);
                    INSERT INTO action_touch VALUES (1, 'watch_state', 1, 5, NULL);
                    INSERT INTO meta VALUES ('kept', x'01');
                    """)
        }

        let replica = try replica()

        XCTAssertEqual(try fixture.queuedActions(), [])
        XCTAssertEqual(replica.kept("kept"), Data([1]))
        try await watch(queue(replica), item: 40)
        let (profile, touches) = try await replica.read { db in
            (
                try String.fetchOne(
                    db, sql: "SELECT type FROM pragma_table_info('action', 'queue') WHERE name = 'profile_id'"),
                try Int.fetchOne(db, sql: "SELECT count(*) FROM queue.action_touch")
            )
        }
        XCTAssertEqual(profile, "BLOB")
        XCTAssertEqual(touches, 1, "the old action's touched keys went with it")
    }

    func testAReplicaOfIntegerIdsIsDroppedForASnapshot() async throws {
        try await session { replica, _ in
            try await replica.write { try $0.execute(sql: "UPDATE replica_meta SET household_id = 7") }
        }

        XCTAssertTrue(try fixture.open().isEmpty, "a v1 replica fails its check")
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

    /// A create the server made but whose answer it lost meets its own id
    /// when sent again; its rows come by sync, so nothing is told.
    func testACreateAnsweredConflictOnItsOwnIdIsNotTold() async throws {
        let replica = try replica()
        let queue = queue(replica)
        for create in Self.creates { try await queue.act(as: 1, touching: [], call: create, apply: { _, _ in }) }
        transport.respond = { sent in
            Self.answer(sent, rejecting: Dictionary(uniqueKeysWithValues: Self.createIds.map { ($0, "conflict") }))
        }

        let flushed = await queue.flush()

        XCTAssertEqual(flushed, .done)
        XCTAssertEqual(batches().map { $0.actions.map(\.operationId) }, [Self.createIds])
        XCTAssertEqual(notices.all, [])
        let left = try await queued(replica)
        XCTAssertEqual(left, [])
    }

    func testAnotherRefusalOfACreateAndAConflictOnAnythingElseAreTold() async throws {
        let replica = try replica()
        let queue = queue(replica)
        try await queue.act(as: 1, touching: [], call: Self.creates[0], apply: { _, _ in })
        try await queue.act(
            as: 1, touching: [],
            call: { client, _ in
                _ = try await client.replacePlaylist(
                    path: .init(profileId: 1, playlistId: 9), body: .json(.init(name: "Late", kind: .movies)))
            }, apply: { _, _ in })
        let codes = ["createPlaylist": "forbidden", "replacePlaylist": "conflict"]
        transport.respond = { Self.answer($0, rejecting: codes) }

        _ = await queue.flush()

        XCTAssertEqual(notices.all, ["createPlaylist forbidden", "replacePlaylist conflict"])
    }

    private static let createIds = [
        "createPlaylist", "addPlaylistEntry", "addPlaylistEntries", "createCollection", "createStation",
    ]

    /// One call of each operation in `createIds`, in that order.
    private static let creates: [@Sendable (Client, Date) async throws -> Void] = [
        { client, _ in
            _ = try await client.createPlaylist(
                path: .init(profileId: 1), body: .json(.init(id: 9, name: "Late", kind: .movies)))
        },
        { client, _ in
            _ = try await client.addPlaylistEntry(
                path: .init(profileId: 1, playlistId: 9), body: .json(.init(id: 10, itemId: 40)))
        },
        { client, _ in
            _ = try await client.addPlaylistEntries(
                path: .init(profileId: 1, playlistId: 9), body: .json(.init(entries: [.init(id: 11, itemId: 40)])))
        },
        { client, _ in _ = try await client.createCollection(body: .json(.init(id: 12, name: "Late"))) },
        { client, _ in _ = try await client.createStation(body: .json(.init(id: 13, name: "Late", kind: .movies))) },
    ]

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
        XCTAssertEqual(batches().map { $0.actions.map(\.path) }, [["/profiles/\(UID.n(1))/watch-state/\(UID.n(40))"]])
    }
}
