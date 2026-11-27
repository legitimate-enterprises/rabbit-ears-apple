import Foundation
import GRDB
import HTTPTypes
import OpenAPIRuntime
import XCTest

@testable import RabbitEarsKit

extension SyncEngineTests {
    func testTheDoorbellCatchesUpOnEntryAndOnEachRing() async throws {
        try adopt(version: 5, titles: ["Antenna"])
        changes { query in
            query == "schema=1&since=5"
                ? (.ok, SyncFixture.diff(version: 6, tables: [Self.movie(3, "Dish")]))
                : (.ok, SyncFixture.diff(version: 7))
        }
        var rings = 0
        transport.routes.respond = { [respond = transport.routes.respond] sent in
            guard sent.path == "/sync/version" else { return respond?(sent) }
            rings += 1
            switch rings {
            case 1: return (.ok, #"{"changed":false,"ranges":\#(SyncFixture.ranges())}"#)
            case 2: return (.ok, #"{"changed":true,"ranges":\#(SyncFixture.ranges())}"#)
            default: return (.unauthorized, Fixtures.error("unauthorized"))
            }
        }

        await engine().follow()

        XCTAssertEqual(queries, ["schema=1&since=5", "schema=1&since=6"])
        XCTAssertEqual(transport.routes.queries(.get, "/sync/version"), ["after=6", "after=6", "after=7"])
        let signOuts = await calls.signOuts
        XCTAssertEqual(signOuts, 1, "a device the server no longer knows is signed out")
    }

    func testAnUnauthorizedPullSignsOutAndStops() async throws {
        try adopt(version: 5, titles: ["Antenna"])
        changes { _ in (.unauthorized, Fixtures.error("unauthorized")) }

        await engine().follow(sleep: { _ in XCTFail("no retry") })

        let signOuts = await calls.signOuts
        XCTAssertEqual(signOuts, 1)
        XCTAssertEqual(queries.count, 1)
    }

    func testFailuresBackOffUpToThirtySeconds() async throws {
        try adopt(version: 5, titles: ["Antenna"])
        var asked = 0
        changes { _ in
            asked += 1
            return asked <= 7
                ? (.internalServerError, Fixtures.error("internal")) : (.notFound, Fixtures.error("not_found"))
        }
        let slept = Waits()

        await engine().follow(sleep: { await slept.add($0) })

        let waits = await slept.all
        XCTAssertEqual(waits, [1, 2, 4, 8, 16, 30, 30].map(Duration.seconds))
        let signOuts = await calls.signOuts
        XCTAssertEqual(signOuts, 0, "a server without sync is not asked again, and nobody is signed out")
    }

    func testAWakeCutsTheBackoffShort() async throws {
        try adopt(version: 5, titles: ["Antenna"])
        var asked = 0
        changes { _ in
            asked += 1
            return asked == 1 ? (.internalServerError, Fixtures.error("internal")) : (.ok, SyncFixture.diff(version: 6))
        }
        transport.routes.routes["GET /sync/version"] = (.unauthorized, Fixtures.error("unauthorized"))
        let slept = Waits()
        let done = expectation(description: "signed out")
        let engine = engine(signOut: { done.fulfill() })

        let following = Task { await engine.follow(sleep: { await slept.add($0, hold: true) }) }
        while await slept.all.isEmpty { await Task.yield() }
        engine.wake()

        await fulfillment(of: [done], timeout: 5)
        await following.value
        XCTAssertEqual(queries, ["schema=1&since=5", "schema=1&since=5"])
    }

    func testCatchUpsAtOnceShareOnePass() async throws {
        try adopt(version: 5, titles: ["Antenna"])
        changes { _ in (.ok, SyncFixture.diff(version: 8)) }
        transport.routes.hold = { _ in try await Task.sleep(for: .milliseconds(100)) }
        let engine = engine()

        async let first: Void = engine.catchUp()
        async let second: Void = engine.catchUp()
        _ = try await (first, second)
        try await engine.catchUp()

        XCTAssertEqual(queries, ["schema=1&since=5", "schema=1&since=8"])
        let flushes = await calls.flushes
        XCTAssertEqual(flushes, 2)
    }

    func testALocalResetSnapshotsAgainAndKeepsUnsentActions() async throws {
        try adopt(version: 5, titles: ["Antenna"])
        try await replica.write { try $0.execute(sql: ReplicaFixture.enqueue("a")) }
        try serve(version: 12, titles: ["Zed"])
        changes { $0.contains("since=") ? (.ok, SyncFixture.diff(version: 12)) : (.ok, SyncFixture.mode("snapshot")) }
        let calls = calls
        let fixture = fixture!
        let replica = replica!

        try await engine(flush: {
            let queue = try fixture.queuedActions()
            await calls.flushed(queue: queue)
            if await calls.flushes == 2 { try await replica.write { try $0.execute(sql: "DELETE FROM queue.action") } }
        }).reset()

        let queues = await calls.queues
        XCTAssertEqual(queues, [["a"], ["a"]], "the action outlives the reset and is flushed after it")
        XCTAssertEqual(queries, ["schema=1", "schema=1&since=12", "schema=1&since=12"])
        try await expectRows("SELECT parsed_title FROM item", ["Zed"])
        try await expectState(["12 nil"])
    }

    func testEachJSONScalarKindKeepsItsSQLiteStorageClass() async throws {
        try adopt(version: 5, titles: ["Antenna"])
        changes { _ in
            (
                .ok,
                SyncFixture.diff(
                    version: 6,
                    tables: [
                        .init(
                            "watch_state", #"["account_id","item_id","position_ms","watched","updated_at"]"#,
                            #"[[1,1,2.5,1,9007199254740993],[1,2,-3,0,5]]"#),
                        .init("account_card", #"["id","name","kind","color"]"#, #"[[2,"Robin","kid",null]]"#),
                    ])
            )
        }

        try await engine().catchUp()

        try await expectRows(
            "SELECT typeof(position_ms), position_ms, updated_at FROM watch_state ORDER BY item_id",
            ["real 2.5 9007199254740993", "integer -3 5"], "a fraction is REAL, an integer INTEGER and exact")
        try await expectRows("SELECT name, typeof(color) FROM account_card", ["Robin null"])
    }

    func testABooleanOrNestedCellIsRefusedWhole() async throws {
        try adopt(version: 5, titles: ["Antenna"])
        for cell in ["true", "[1]", #"{"a":1}"#] {
            changes { _ in
                (
                    .ok,
                    SyncFixture.diff(
                        version: 8,
                        tables: [.init("item", #"["id","kind","parsed_title"]"#, #"[[3,"movie",\#(cell)]]"#)])
                )
            }

            do {
                try await engine().catchUp()
                XCTFail("applied \(cell)")
            } catch {
                XCTAssertTrue(error is SyncEngine.Failure, "\(cell): \(error)")
            }

            try await expectRows("SELECT id FROM item ORDER BY id", ["1"], cell)
        }
    }
}
