import Foundation
import GRDB
import HTTPTypes
import OpenAPIRuntime
import RabbitEarsAPI
import Synchronization
import XCTest

@testable import RabbitEarsKit

final class ActionQueueTests: ActionQueueCase {
    // MARK: Atomicity

    func testTheLocalChangeAndItsActionCommitTogether() async throws {
        let replica = try replica()
        let queue = queue(replica)

        try await watch(queue, item: 40)

        let (rows, action, uuid, touched) = try await replica.read { db in
            (
                try Int.fetchOne(db, sql: "SELECT count(*) FROM watch_state WHERE item_id = \(sqlID(40))"),
                try Row.fetchAll(db, sql: "SELECT profile_id, at FROM queue.action").map {
                    "\($0["profile_id"] as UID) \($0["at"] as Int64)"
                },
                try String.fetchOne(db, sql: "SELECT uuid FROM queue.action") ?? "",
                try Row.fetchAll(db, sql: "SELECT table_name, key1, key2, key3 FROM queue.action_touch")
                    .map { Array($0.databaseValues) }
            )
        }
        XCTAssertEqual(rows, 1)
        XCTAssertEqual(
            action, ["\(UID.n(1)) 1800000000123"], "the acting profile as a blob, and at in Unix milliseconds")
        XCTAssertNotNil(UUID(uuidString: uuid))
        XCTAssertEqual(uuid, uuid.lowercased())
        let text = { (id: UID) in id.description.databaseValue }
        XCTAssertEqual(
            touched, [["watch_state".databaseValue, text(1), text(40), .null]], "id key parts are kept as their text")
    }

    func testALocalChangeThatFailsQueuesNothing() async throws {
        struct Refused: Error {}
        let replica = try replica()
        let queue = queue(replica)

        do {
            try await queue.act(
                as: 1, touching: [try .row("watch_state", 1, 40)],
                call: {
                    _ = try await $0.recordPlay(path: .init(profileId: 1, itemId: 40), body: .json(.init(at: $1)))
                },
                apply: { db, _ in
                    try db.execute(sql: "INSERT INTO watch_state VALUES (\(sqlID(1)), \(sqlID(40)), 0)")
                    throw Refused()
                })
            XCTFail("the failure is the caller's")
        } catch is Refused {}

        let counts = try await replica.read { db in
            try ["watch_state", "queue.action", "queue.action_touch"].map {
                try Int.fetchOne(db, sql: "SELECT count(*) FROM \($0)")
            }
        }
        XCTAssertEqual(counts, [0, 0, 0])
        let flushed = await queue.flush()
        XCTAssertEqual(flushed, .done)
        XCTAssertEqual(batches().count, 0)
    }

    // MARK: Flushing

    func testABurstGoesAsOneBatchOnceTheDebounceEnds() async throws {
        let replica = try replica()
        let queue = queue(replica)

        for item in 40...42 { try await watch(queue, item: .n(item)) }
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(batches().count, 0, "nothing goes before the debounce ends")
        gate.open()
        await until { batches().count == 1 }
        try await until { try await queued(replica).isEmpty }

        XCTAssertEqual(
            batches().map { $0.actions.map(\.path) },
            [(40...42).map { "/profiles/\(UID.n(1))/watch-state/\(UID.n($0))" }])
        let batch = try XCTUnwrap(batches().first)
        XCTAssertEqual(batch.apiVersion, ActionQueue.apiVersion)
        XCTAssertEqual(batch.actions.map(\.actingProfileId), [1, 1, 1])
        XCTAssertEqual(batch.actions.map(\.at), Array(repeating: Self.now, count: 3))
        XCTAssertEqual(
            batch.actions.map(\.touched),
            try (40...42).map { [try .row("watch_state", 1, .n($0))] })
        XCTAssertEqual(firstBody()?["watched"] as? Bool, true)
        XCTAssertEqual(firstBody()?["at"] as? String, "2027-01-15T08:00:00.123Z")
        XCTAssertEqual(kicks.all.count, 1)
    }

    func testActionsGoInSeqOrderAtMostAHundredABatch() async throws {
        let replica = try replica()
        let queue = queue(replica)
        let uuids = (0...100).map { String(format: "a%03d", $0) }
        try await replica.write { db in for uuid in uuids { try db.execute(sql: ReplicaFixture.enqueue(uuid)) } }

        let flushed = await queue.flush()

        XCTAssertEqual(flushed, .done)
        XCTAssertEqual(batches().map(\.actions.count), [100, 1])
        XCTAssertEqual(batches().flatMap { $0.actions.map(\.id) }, uuids)
        let seqs = batches().flatMap { $0.actions.map(\.seq) }
        XCTAssertEqual(seqs, seqs.sorted())
        XCTAssertEqual(firstBody()?.count, 0)
        let left = try await queued(replica)
        XCTAssertEqual(left, [])
        XCTAssertEqual(kicks.all.count, 1, "one kick a flush")
    }

    func testOnlyAnsweredActionsLeaveAndTheRestGoAgainWithTheirIds() async throws {
        let replica = try replica()
        let queue = queue(replica)
        for item in 40...42 { try await watch(queue, item: .n(item)) }
        let ids = try await queued(replica)
        // As when the server fails at the second action: it and those after it go unanswered.
        transport.respond = { Self.answer($0, answered: 1) }

        let first = await queue.flush()

        XCTAssertEqual(first, .offline)
        let left = try await queued(replica)
        XCTAssertEqual(left, Array(ids.dropFirst()))
        let touches = try await replica.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM queue.action_touch") }
        XCTAssertEqual(touches, 2, "the answered action's touched keys go with it")

        transport.respond = { Self.answer($0) }
        let second = await queue.flush()

        XCTAssertEqual(second, .done)
        XCTAssertEqual(batches().map { $0.actions.map(\.id) }, [ids, Array(ids.dropFirst())])
        let empty = try await queued(replica)
        XCTAssertEqual(empty, [])
    }

    func testAnActionTakenWhileABatchIsInFlightStaysForTheNext() async throws {
        let replica = try replica()
        let queue = queue(replica)
        try await watch(queue, item: 40)
        let (arrived, arrival) = AsyncStream<Void>.makeStream()
        let release = Latch()
        transport.hold = { _ in
            arrival.yield()
            await release.wait()
        }

        async let flushed = queue.flush()
        var arrivals = arrived.makeAsyncIterator()
        _ = await arrivals.next()
        try await watch(queue, item: 41)
        transport.hold = nil
        release.open()

        let outcome = await flushed
        XCTAssertEqual(outcome, .done)
        XCTAssertEqual(
            batches().map { $0.actions.map(\.path) },
            [["/profiles/\(UID.n(1))/watch-state/\(UID.n(40))"], ["/profiles/\(UID.n(1))/watch-state/\(UID.n(41))"]])
    }

    func testFlushesAskedWhileOneRunsShareIt() async throws {
        let replica = try replica()
        let queue = queue(replica)
        try await watch(queue, item: 40)
        let release = Latch()
        let (arrived, arrival) = AsyncStream<Void>.makeStream()
        transport.hold = { _ in
            arrival.yield()
            await release.wait()
        }

        async let first = queue.flush()
        var arrivals = arrived.makeAsyncIterator()
        _ = await arrivals.next()
        async let second = queue.flush()
        async let third = queue.flush()
        try? await Task.sleep(for: .milliseconds(50))
        release.open()

        let outcomes = await [first, second, third]
        XCTAssertEqual(outcomes, [.done, .done, .done])
        XCTAssertEqual(batches().count, 1)
    }

    func testARejectedActionIsDroppedAndToldByOperationAndCode() async throws {
        let replica = try replica()
        let queue = queue(replica)
        try await watch(queue, item: 40)
        try await queue.act(
            as: 1, touching: [try .row("playlist_entry", 9)],
            call: {
                _ = try await $0.addPlaylistEntry(
                    path: .init(profileId: 2, playlistId: 3), body: .json(.init(itemId: 40)))
                _ = $1
            }, apply: { _, _ in })
        transport.respond = { Self.answer($0, rejecting: ["addPlaylistEntry": "forbidden"]) }

        let flushed = await queue.flush()

        XCTAssertEqual(flushed, .done)
        XCTAssertEqual(notices.all, ["addPlaylistEntry forbidden"])
        let left = try await queued(replica)
        XCTAssertEqual(left, [])
        let rows = try await replica.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM watch_state") }
        XCTAssertEqual(rows, 1, "no local rollback; catch-up restores what the server holds")
    }

    func testABatchRefusedWholeGoesOneAtATimeAndOnlyTheActionRefusedAloneIsDropped() async throws {
        let replica = try replica()
        let queue = queue(replica)
        for item in 40...42 { try await watch(queue, item: .n(item)) }
        let ids = try await queued(replica)
        let refused = "/profiles/\(UID.n(1))/watch-state/\(UID.n(41))"
        transport.respond = { sent in
            let batch = Fixtures.decode(sent.body, as: Batch.self)
            guard batch.actions.contains(where: { $0.path == refused }) else { return Self.answer(sent) }
            return (.badRequest, Fixtures.fieldError("actions[1].body"))
        }

        let flushed = await queue.flush()

        XCTAssertEqual(flushed, .done)
        XCTAssertEqual(batches().map { $0.actions.map(\.id) }, [ids, [ids[0]], [ids[1]], [ids[2]]])
        XCTAssertEqual(notices.all, ["putWatchState bad_request"])
        let left = try await queued(replica)
        XCTAssertEqual(left, [])
        XCTAssertEqual(kicks.all.count, 1)
    }

    func testAFailedSendLosesNothing() async throws {
        let replica = try replica()
        let queue = queue(replica)
        try await watch(queue, item: 40)
        let ids = try await queued(replica)
        transport.failure = URLError(.notConnectedToInternet)

        let offline = await queue.flush()

        XCTAssertEqual(offline, .offline)
        let kept = try await queued(replica)
        XCTAssertEqual(kept, ids)
        XCTAssertEqual(kicks.all.count, 0)
        XCTAssertEqual(notices.all, [])

        transport.failure = nil
        let online = await queue.flush()
        XCTAssertEqual(online, .done)
        XCTAssertEqual(batches().map { $0.actions.map(\.id) }, [ids])
    }

    func testADeviceTheServerNoLongerKnowsKeepsTheQueueAndIsToldApart() async throws {
        let replica = try replica()
        let queue = queue(replica)
        try await watch(queue, item: 40)
        let ids = try await queued(replica)
        transport.respond = { _ in (.unauthorized, Fixtures.error("unauthorized")) }

        let flushed = await queue.flush()

        guard case .refused(let error) = flushed else { return XCTFail("\(flushed)") }
        XCTAssertEqual(error.code, .unauthorized)
        let kept = try await queued(replica)
        XCTAssertEqual(kept, ids)
        XCTAssertEqual(notices.all, [])
        XCTAssertEqual(kicks.all.count, 0)
    }

    func testAnUnsupportedVersionKeepsTheQueueAndStopsFlushing() async throws {
        let replica = try replica()
        let queue = queue(replica)
        try await watch(queue, item: 40)
        let ids = try await queued(replica)
        transport.respond = { Self.answer($0, rejecting: ["putWatchState": "unsupported_version"]) }

        let first = await queue.flush()
        let second = await queue.flush()

        XCTAssertEqual([first, second], [.unsupported, .unsupported])
        XCTAssertEqual(batches().count, 1, "no batch after the server refused this build")
        let kept = try await queued(replica)
        XCTAssertEqual(kept, ids)
        XCTAssertEqual(notices.all, [])
        XCTAssertEqual(kicks.all.count, 0)
    }

    // MARK: Limits

    func testAnActionTouchingMoreRowsThanTheSpecAllowsIsSentAtOnceAfterTheQueue() async throws {
        let replica = try replica()
        let queue = queue(replica)
        try await watch(queue, item: 40)
        try await mark(queue, ActionQueue.touchedLimit)
        transport.routes["PUT /profiles/\(UID.n(1))/watch-state/batch"] = (.noContent, "")

        try await mark(queue, ActionQueue.touchedLimit + 1)

        XCTAssertEqual(transport.sent.map(\.path), ["/sync/actions", "/profiles/\(UID.n(1))/watch-state/batch"])
        XCTAssertEqual(batches().map { $0.actions.map(\.touched.count) }, [[1, ActionQueue.touchedLimit]])
        let ids = transport.json(.put, "/profiles/\(UID.n(1))/watch-state/batch")?["itemIds"] as? [String]
        XCTAssertEqual(ids?.count, ActionQueue.touchedLimit + 1)
        let left = try await queued(replica)
        XCTAssertEqual(left, [])
        let applied = try await replica.read {
            try UID.fetchAll($0, sql: "SELECT item_id FROM watch_state ORDER BY item_id")
        }
        XCTAssertEqual(applied, [40, .n(ActionQueue.touchedLimit)], "the server's rows come back by sync")
        XCTAssertEqual(kicks.all.count, 2, "a catch-up after each")
    }

    func testLargeActionsGoInBatchesThatFitTheRequestBodyLimit() async throws {
        let replica = try replica()
        let queue = queue(replica)
        for _ in 0..<30 { try await mark(queue, ActionQueue.touchedLimit) }
        let ids = try await queued(replica)

        let flushed = await queue.flush()

        XCTAssertEqual(flushed, .done)
        let sizes = transport.sent.filter { $0.path == "/sync/actions" }.map(\.body.utf8.count)
        XCTAssertGreaterThan(sizes.reduce(0, +), ActionQueue.bodyLimit, "the queue holds more than one body")
        XCTAssertTrue(sizes.allSatisfy { $0 <= ActionQueue.bodyLimit }, "\(sizes)")
        XCTAssertEqual(batches().flatMap { $0.actions.map(\.id) }, ids)
    }

    /// putWatchStates of `count` items, each touched; its local write is a
    /// row for item `count`.
    private func mark(_ queue: ActionQueue, _ count: Int) async throws {
        let items = (0..<count).map { UID.n($0 + 1000) }
        try await queue.act(
            as: 1, touching: try items.map { try .row("watch_state", 1, $0) },
            call: { client, at in
                _ = try await client.putWatchStates(
                    path: .init(profileId: 1), body: .json(.init(itemIds: items, watched: true, at: at)))
            },
            apply: { db, _ in
                try db.execute(
                    sql: "INSERT OR IGNORE INTO watch_state VALUES (?, ?, 0)", arguments: [UID.n(1), UID.n(count)])
            })
    }

    func testUnsentActionsOutliveASnapshotAndActionsGoOnAfterIt() async throws {
        let replica = try replica()
        let queue = queue(replica)
        try await watch(queue, item: 40)

        try replica.adopt(fixture.snapshot(version: 9))
        try await watch(queue, item: 41)
        let flushed = await queue.flush()

        XCTAssertEqual(flushed, .done)
        XCTAssertEqual(
            batches().map { $0.actions.map(\.path) },
            [["/profiles/\(UID.n(1))/watch-state/\(UID.n(40))", "/profiles/\(UID.n(1))/watch-state/\(UID.n(41))"]])
    }
}

extension ActionQueueTests {
    func testAReplayedActionCarriesIdsAsLowercaseStringsAndIntegerKeyPartsAsIntegers() async throws {
        let replica = try replica()
        let queue = queue(replica)
        try await queue.act(
            as: 1, touching: [try .row("station", 5), try .row("station_day", 5, 3)],
            call: {
                _ = try await $0.deleteStation(path: .init(stationId: 5))
                _ = $1
            }, apply: { _, _ in })

        _ = await queue.flush()

        let actions = try XCTUnwrap(transport.json(.post, "/sync/actions")?["actions"] as? [[String: Any]])
        XCTAssertEqual(actions.first?["actingProfileId"] as? String, UID.n(1).description)
        XCTAssertEqual(actions.first?["path"] as? String, "/stations/\(UID.n(5))")
        let touched = try XCTUnwrap(actions.first?["touched"] as? [[String: Any]])
        let keys = touched.map { $0["key"] as? [Any] ?? [] }
        XCTAssertEqual(keys.first?.first as? String, UID.n(5).description)
        XCTAssertEqual(keys.last?.first as? String, UID.n(5).description)
        XCTAssertEqual(keys.last?.last as? Int, 3, "an integer key part stays an integer")
        XCTAssertNil(keys.last?.last as? String)
    }
}
