import Foundation
import GRDB
import XCTest

@testable import RabbitEarsKit

final class ReplicaTests: XCTestCase {
    var fixture: ReplicaFixture!

    override func setUp() {
        fixture = ReplicaFixture()
    }

    override func tearDown() {
        fixture.remove()
    }

    private func titles(_ replica: Replica) async throws -> [String] {
        try await replica.read { try String.fetchAll($0, sql: "SELECT title FROM item ORDER BY id") }
    }

    private func assertEmpty(_ replica: Replica, file: StaticString = #filePath, line: UInt = #line) async {
        XCTAssertTrue(replica.isEmpty, file: file, line: line)
        do {
            _ = try await titles(replica)
            XCTFail("read with no replica", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? Replica.Failure, .empty, file: file, line: line)
        }
    }

    func testAnEmptyDirectoryOpensWithNoReplicaAndAnEmptyQueue() async throws {
        let replica = try fixture.open()

        await assertEmpty(replica)
        XCTAssertFalse(replica.lostActions)
        XCTAssertEqual(try fixture.queuedActions(), [])
        let values = try fixture.directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
    }

    func testAnAdoptedSnapshotIsReadableAndKeptAcrossLaunches() async throws {
        let replica = try fixture.open()
        let snapshot = try fixture.snapshot(version: 5, titles: ["Antenna", "Bunny"])

        try replica.adopt(snapshot)

        XCTAssertFalse(replica.isEmpty)
        XCTAssertFalse(fixture.exists(snapshot), "the download is taken, not copied")
        let read = try await titles(replica)
        XCTAssertEqual(read, ["Antenna", "Bunny"])
        let shown = try await replica.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM item_shown") }
        XCTAssertEqual(shown, 2, "the snapshot's views come with it")
        let synced = try await replica.read {
            try Int64.fetchOne($0, sql: "SELECT version FROM sync_state WHERE cursor IS NULL")
        }
        XCTAssertEqual(synced, 5, "sync state starts at the snapshot's version")
        let keys = try await replica.read { try Int.fetchOne($0, sql: "PRAGMA foreign_keys") }
        XCTAssertEqual(keys, 0)

        let relaunched = try await titles(try fixture.open())
        XCTAssertEqual(relaunched, ["Antenna", "Bunny"])
    }

    /// Another connection takes the queue's write lock and keeps it a moment.
    private func holdTheQueue() throws {
        let other = try DatabaseQueue(path: fixture.queue.path(percentEncoded: false))
        let held = DispatchSemaphore(value: 0)
        Thread {
            try? other.write { _ in
                held.signal()
                Thread.sleep(forTimeInterval: 0.3)
            }
        }.start()
        held.wait()
    }

    func testAdoptingAndWritingWaitOutAnotherWriterOfTheQueue() async throws {
        let replica = try fixture.open()
        try replica.adopt(fixture.snapshot(version: 5))

        try holdTheQueue()
        try replica.adopt(fixture.snapshot(version: 6))
        try holdTheQueue()
        try await replica.write { try $0.execute(sql: "INSERT INTO queue.meta VALUES ('k', 1)") }
    }

    func testAdoptingReplacesTheReplicaAndDeletesTheOldFile() async throws {
        let replica = try fixture.open()
        try replica.adopt(fixture.snapshot(version: 5, titles: ["Antenna"]))
        let first = try fixture.current()

        try replica.adopt(fixture.snapshot(version: 7, titles: ["Bunny"]))
        let second = try fixture.current()
        try replica.adopt(fixture.snapshot(version: 7, titles: ["Cable"]))

        let read = try await titles(replica)
        XCTAssertEqual(read, ["Cable"], "a snapshot at the same version replaces the current one too")
        XCTAssertEqual(try fixture.names().filter { $0.hasPrefix(first) || $0.hasPrefix(second) }, [])
        XCTAssertEqual(try fixture.strays(), [])
    }

    func testPreparationRunsInsideTheSnapshotBeforeItIsCurrent() async throws {
        let replica = try fixture.open()
        try replica.adopt(fixture.snapshot(version: 5, titles: ["Antenna"]))

        try replica.adopt(fixture.snapshot(version: 7, titles: ["Bunny"])) { db in
            let synced = try Int64.fetchOne(db, sql: "SELECT version FROM sync_state")
            XCTAssertEqual(synced, 7)
            try db.execute(sql: "CREATE TABLE fts_item(id INTEGER PRIMARY KEY)")
            try db.execute(sql: "INSERT INTO fts_item SELECT id FROM item")
        }
        let built = try await replica.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM fts_item") }
        XCTAssertEqual(built, 1)

        struct Refused: Error {}
        let refused = try fixture.snapshot(version: 9, titles: ["Cable"])
        XCTAssertThrowsError(try replica.adopt(refused) { _ in throw Refused() }) { XCTAssertTrue($0 is Refused) }
        let read = try await titles(replica)
        XCTAssertEqual(read, ["Bunny"])
        XCTAssertEqual(try fixture.strays(), [])
    }

    func testACrashBeforeThePointerMovesKeepsTheOldReplica() async throws {
        try fixture.open().adopt(fixture.snapshot(version: 5, titles: ["Antenna"]))
        let renamed = fixture.directory.appending(path: "replica-9-\(UUID().uuidString).sqlite")
        try FileManager.default.moveItem(at: fixture.snapshot(version: 9, titles: ["Bunny"]), to: renamed)

        let read = try await titles(try fixture.open())

        XCTAssertEqual(read, ["Antenna"])
        XCTAssertFalse(fixture.exists(renamed))
    }

    func testACrashAfterThePointerMovedOpensTheNewReplica() async throws {
        try fixture.open().adopt(fixture.snapshot(version: 5, titles: ["Antenna"]))
        let old = try fixture.current()
        let name = "replica-9-\(UUID().uuidString).sqlite"
        try FileManager.default.moveItem(
            at: fixture.snapshot(version: 9, titles: ["Bunny"]), to: fixture.directory.appending(path: name))
        try Data(name.utf8).write(to: fixture.pointer, options: .atomic)

        let read = try await titles(try fixture.open())

        XCTAssertEqual(read, ["Bunny"])
        XCTAssertEqual(try fixture.names().filter { $0.hasPrefix(old) }, [])
    }

    func testStrayFilesAndUnfinishedDownloadsAreDeletedAtOpen() async throws {
        try fixture.open().adopt(fixture.snapshot(version: 5))
        for name in ["replica-3-old.sqlite", "replica-3-old.sqlite-wal", "\(UUID().uuidString).part", "junk"] {
            try Data("x".utf8).write(to: fixture.directory.appending(path: name))
        }

        _ = try fixture.open()

        XCTAssertEqual(try fixture.strays(), [])
        XCTAssertTrue(fixture.exists(fixture.directory.appending(path: try fixture.current())))
    }

    func testAReplicaThatIsNotADatabaseLeavesTheStoreEmptyAndTheQueueAsItWas() async throws {
        try await assertDamagedReplicaOpensEmpty(ReplicaFixture.breakHeader)
    }

    func testAReplicaWithABrokenPageLeavesTheStoreEmptyAndTheQueueAsItWas() async throws {
        try await assertDamagedReplicaOpensEmpty(ReplicaFixture.breakPage)
    }

    func testAMissingReplicaLeavesTheStoreEmptyAndTheQueueAsItWas() async throws {
        try await assertDamagedReplicaOpensEmpty { try FileManager.default.removeItem(at: $0) }
    }

    private func assertDamagedReplicaOpensEmpty(_ damage: (URL) throws -> Void) async throws {
        try await fixture.closedWithAnAction()
        let file = fixture.directory.appending(path: try fixture.current())
        try damage(file)

        let reopened = try fixture.open()

        await assertEmpty(reopened)
        XCTAssertFalse(reopened.lostActions)
        XCTAssertEqual(try fixture.queuedActions(), ["a"])
        XCTAssertFalse(fixture.exists(fixture.pointer))
        XCTAssertEqual(try fixture.strays(), [])
    }

    func testUnsentActionsOutliveASwap() async throws {
        let replica = try fixture.open()
        try replica.adopt(fixture.snapshot(version: 5))
        try await replica.write { try $0.execute(sql: ReplicaFixture.enqueue("a")) }

        try replica.adopt(fixture.snapshot(version: 7))

        let queued = try await replica.read { try String.fetchAll($0, sql: "SELECT uuid FROM queue.action") }
        XCTAssertEqual(queued, ["a"])
    }

    func testTheQueueKeepsActionsAndTheKeysTheyTouch() async throws {
        let replica = try fixture.open()
        try replica.adopt(fixture.snapshot(version: 5))

        let touched = try await replica.write { db in
            try db.execute(sql: ReplicaFixture.enqueue("a"))
            try db.execute(
                sql: "INSERT INTO queue.action_touch(action, table_name, key1, key2) VALUES (?, 'watch_state', 1, 5)",
                arguments: [db.lastInsertedRowID])
            try db.execute(sql: "INSERT INTO queue.meta(key, value) VALUES ('flushed', 1)")
            let sql =
                "SELECT a.uuid, t.table_name, t.key1, t.key2, t.key3 FROM queue.action a "
                + "JOIN queue.action_touch t ON t.action = a.seq"
            return try Row.fetchAll(db, sql: sql).map { Array($0.databaseValues) }
        }

        XCTAssertEqual(
            touched, [["a".databaseValue, "watch_state".databaseValue, 1.databaseValue, 5.databaseValue, .null]])
    }

    func testASnapshotThisBuildCannotReadIsRefusedAndTheReplicaKept() async throws {
        let replica = try fixture.open()
        try replica.adopt(fixture.snapshot(version: 5, titles: ["Antenna"]))
        let newer = try fixture.snapshot(version: 7, schema: Replica.schemas.upperBound + 1)
        let broken = try fixture.snapshot(version: 8)
        try ReplicaFixture.breakPage(broken)
        let garbage = try fixture.snapshot(version: 9)
        try ReplicaFixture.breakHeader(garbage)

        XCTAssertThrowsError(try replica.adopt(newer)) {
            XCTAssertEqual($0 as? Replica.Failure, .unsupported(schema: Replica.schemas.upperBound + 1))
        }
        XCTAssertThrowsError(try replica.adopt(broken)) { XCTAssertEqual($0 as? Replica.Failure, .damaged) }
        XCTAssertThrowsError(try replica.adopt(garbage))

        let read = try await titles(replica)
        XCTAssertEqual(read, ["Antenna"])
        XCTAssertEqual(try fixture.strays(), [])
        XCTAssertFalse(fixture.exists(newer), "a refused download is not kept")
    }

    func testADamagedQueueIsReplacedAndTheLossReported() async throws {
        try await fixture.closedWithAnAction()
        try ReplicaFixture.breakHeader(fixture.queue)

        let reopened = try fixture.open()

        XCTAssertTrue(reopened.lostActions)
        XCTAssertEqual(try fixture.queuedActions(), [])
        let read = try await titles(reopened)
        XCTAssertEqual(read, ["Antenna"], "the replica is kept")
        XCTAssertFalse(try fixture.open().lostActions)
    }

    func testChangesNameTheGroupsACommitTouchedAndEveryGroupOnASwap() async throws {
        let replica = try fixture.open()
        var changes = replica.changes.makeAsyncIterator()
        try replica.adopt(fixture.snapshot(version: 5))
        var swapped: Set<Replica.Group> = []
        for _ in Replica.Group.allCases {
            let group = await changes.next()
            swapped.insert(try XCTUnwrap(group))
        }
        XCTAssertEqual(swapped, Set(Replica.Group.allCases))

        try await replica.write { try $0.execute(sql: "INSERT INTO item VALUES (100, 'Cable')") }
        let catalog = await changes.next()
        XCTAssertEqual(catalog, .library)

        try await replica.write { try $0.execute(sql: ReplicaFixture.enqueue("a")) }
        struct Undone: Error {}
        _ = try? await replica.write { db in
            try db.execute(sql: "INSERT INTO playlist VALUES (1, 1, 'Road trip')")
            throw Undone()
        }
        try await replica.write { try $0.execute(sql: "INSERT INTO watch_state VALUES (1, 100, 5000)") }
        let watched = await changes.next()
        XCTAssertEqual(watched, .watched, "the queue and a rolled-back write change no group")

        try await replica.write { try $0.execute(sql: "INSERT INTO playlist VALUES (1, 1, 'Road trip')") }
        let playlists = await changes.next()
        XCTAssertEqual(playlists, .playlists)
    }

    func testWipingDeletesTheReplicaAndTheQueue() async throws {
        let replica = try fixture.open()
        try replica.adopt(fixture.snapshot(version: 5))
        try await replica.write { try $0.execute(sql: ReplicaFixture.enqueue("a")) }

        try replica.wipe()

        await assertEmpty(replica)
        XCTAssertFalse(fixture.exists(fixture.directory))

        try replica.adopt(fixture.snapshot(version: 2, titles: ["Bunny"]))
        let read = try await titles(replica)
        XCTAssertEqual(read, ["Bunny"], "signed in again, a snapshot is adopted afresh")
        XCTAssertEqual(try fixture.queuedActions(), [])
    }

    func testReadsDuringSwapsEachSeeOneWholeReplicaNeverAnOlderOne() async throws {
        let replica = try fixture.open()
        try replica.adopt(fixture.snapshot(version: 1, titles: ["T"]))
        let snapshots = try (2...6).map {
            try fixture.snapshot(version: Int64($0), titles: Array(repeating: "T", count: $0))
        }

        // The item count when it is the replica's version, as each snapshot here has it; 0 otherwise.
        let whole = "SELECT CASE count(*) WHEN max(version) THEN count(*) ELSE 0 END FROM item, sync_state"

        try await withThrowingTaskGroup(of: [Int].self) { group in
            for _ in 0..<8 {
                group.addTask {
                    var seen: [Int] = []
                    while seen.last != 6, !Task.isCancelled {
                        seen.append(
                            try await replica.read { try Int.fetchOne($0, sql: whole) ?? 0 })
                    }
                    return seen
                }
            }
            group.addTask {
                for snapshot in snapshots { try replica.adopt(snapshot) }
                return []
            }
            for try await seen in group {
                XCTAssertEqual(seen, seen.sorted(), "a reader never goes back to an older replica")
                XCTAssertFalse(seen.contains(0), "each read sees one whole replica")
            }
        }
    }
}
