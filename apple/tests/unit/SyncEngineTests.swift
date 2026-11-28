import Foundation
import GRDB
import HTTPTypes
import OpenAPIRuntime
import RabbitEarsAPI
import XCTest

@testable import RabbitEarsKit

/// UID.n(n) as a page's JSON cell.
private func id(_ number: Int) -> String { SyncFixture.id(number) }

@MainActor
final class SyncEngineTests: XCTestCase {
    var fixture: ReplicaFixture!
    var replica: Replica!
    var transport: SyncTransport!
    let calls = Calls()

    override func setUp() async throws {
        fixture = ReplicaFixture()
        replica = try fixture.open()
        transport = SyncTransport()
    }

    override func tearDown() {
        fixture.remove()
    }

    func engine(
        _ replica: Replica? = nil, flush: (@Sendable () async throws -> Void)? = nil,
        signOut: (@MainActor () async -> Void)? = nil
    ) -> SyncEngine {
        let calls = calls
        return SyncEngine(
            replica: replica ?? self.replica, endpoint: .default, token: "tok", transport: transport,
            flush: flush ?? { await calls.flushed() }, signOut: signOut ?? { await calls.signedOut() })
    }

    /// Answers getSyncChanges by its query, as "schema=1&since=5"; others go to the routes.
    func changes(_ answer: @escaping (String) -> (HTTPResponse.Status, String)?) {
        transport.routes.respond = { $0.path == "/sync/changes" ? answer($0.query) : nil }
    }

    func serve(version: Int64, titles: [String] = [], rows: String = "") throws {
        transport.snapshot = try SyncFixture.snapshot(
            in: fixture.downloads, version: version, titles: titles, rows: rows)
    }

    func adopt(version: Int64, titles: [String] = [], rows: String = "") throws {
        try replica.adopt(
            SyncFixture.snapshot(in: fixture.downloads, version: version, titles: titles, rows: rows),
            prepare: ReplicaSearch.build)
    }

    var queries: [String] { transport.routes.queries(.get, "/sync/changes") }

    func expectRows(
        _ sql: String, _ expected: [String], _ message: String = "", in replica: Replica? = nil,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let actual = try await rows(sql, replica)
        XCTAssertEqual(actual, expected, message, file: file, line: line)
    }

    func expectState(
        _ expected: [String], _ message: String = "", in replica: Replica? = nil, file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        try await expectRows(
            "SELECT version, cursor FROM sync_state", expected, message, in: replica, file: file, line: line)
    }

    func rows(_ sql: String, _ replica: Replica? = nil) async throws -> [String] {
        try await (replica ?? self.replica).read { db in
            try Row.fetchAll(db, sql: sql).map { row in
                row.databaseValues.map { value in
                    switch value.storage {
                    case .null: "nil"
                    case .int64(let number): "\(number)"
                    case .double(let number): "\(number)"
                    case .string(let text): text
                    // A uid.N id reads as its n, so a text id never passes for one.
                    case .blob(let data): UID.fromDatabaseValue(value).flatMap(Self.number) ?? "\(data)"
                    }
                }.joined(separator: " ")
            }
        }
    }

    /// n of an id uid.N(n).
    nonisolated static func number(_ id: UID) -> String? {
        let text = id.description
        guard text.hasPrefix("00000000-0000-7000-8000-") else { return nil }
        return Int(text.suffix(12), radix: 16).map(String.init)
    }

    func expectSearch(
        _ query: String, _ expected: [UID], _ message: String = "", file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let found = try await replica.read { try ReplicaSearch.items(matching: query, in: $0) }
        XCTAssertEqual(found, expected, message, file: file, line: line)
    }

    func testAColdStartTakesASnapshotThenCatchesUpFromItsVersion() async throws {
        try serve(version: 9, titles: ["Antenna", "Bunny"])
        changes { $0.contains("since=") ? (.ok, SyncFixture.diff(version: 9)) : (.ok, SyncFixture.mode("snapshot")) }

        try await engine().catchUp()

        XCTAssertEqual(queries, ["schema=1", "schema=1&since=9"])
        XCTAssertEqual(transport.routes.queries(.get, "/sync/snapshot"), ["schema=1"])
        XCTAssertEqual(transport.routes.sent.first?.authorization, "Bearer tok")
        try await expectRows("SELECT parsed_title FROM item ORDER BY id", ["Antenna", "Bunny"])
        try await expectState(["9 nil"])
        try await expectSearch("unn", [2], "the snapshot is indexed before it is current")
        XCTAssertEqual(try fixture.strays(), [], "no download is left behind")
        let flushes = await calls.flushes
        XCTAssertEqual(flushes, 1)
    }

    func testADiffUpsertsRowsAndDeletesTombstonesByEveryKeyShape() async throws {
        try adopt(
            version: 5, titles: ["Antenna", "Bunny"],
            rows: """
                UPDATE item SET kids_content = 1 WHERE id = \(sqlID(1));
                INSERT INTO item_metadata VALUES (\(sqlID(1)), 'remote', 'Antenna', 'Old');
                INSERT INTO item_genre VALUES (\(sqlID(1)), \(sqlID(10)), 'tmdb'), (\(sqlID(1)), \(sqlID(11)), 'local');
                INSERT INTO watch_state VALUES (\(sqlID(1)), \(sqlID(1)), 0, 0, 1700000000000),
                    (\(sqlID(1)), \(sqlID(2)), 9, 0, 1700000000000);
                INSERT INTO occasion_phrase VALUES (\(sqlID(3)), 'Merry'), (\(sqlID(3)), 'Jolly');
                INSERT INTO account_card VALUES (\(sqlID(2)), 'Robin', 'kid', 'teal');
                """)
        changes { _ in
            (
                .ok,
                SyncFixture.diff(
                    version: 8,
                    tables: [
                        .init(
                            "item", #"["id","kind","parsed_title"]"#,
                            #"[[\#(id(1)),"movie","Cable"],[\#(id(3)),"movie","Dish"]]"#),
                        .init(
                            "item_metadata", #"["item_id","source","title","overview"]"#,
                            #"[[\#(id(1)),"remote","Cable",null]]"#),
                        .init(
                            "watch_state", #"["account_id","item_id","position_ms","watched","changed_at"]"#,
                            #"[[\#(id(1)),\#(id(1)),500,1,1800000000000]]"#),
                        .init(
                            "item_genre", #"["item_id","genre_id","source"]"#,
                            #"[[\#(id(1)),\#(id(12)),"tmdb"],[\#(id(1)),\#(id(11)),"local"]]"#),
                        .init(
                            "account_card", #"["id","name","kind","color"]"#,
                            #"[[\#(id(2)),"Robin","kid",null]]"#),
                    ],
                    tombstones: [
                        ("item", "[[\(id(2))]]"), ("watch_state", "[[\(id(1)),\(id(2))]]"),
                        ("item_genre", #"[[\#(id(1)),\#(id(10)),"tmdb"]]"#),
                        ("occasion_phrase", #"[[\#(id(3)),"Merry"]]"#),
                    ])
            )
        }

        try await engine().catchUp()

        XCTAssertEqual(queries, ["schema=1&since=5"])
        try await expectRows(
            "SELECT id, parsed_title, kids_content FROM item ORDER BY id", ["1 Cable 1", "3 Dish nil"],
            "a column the page leaves out keeps its value")
        try await expectRows("SELECT * FROM item_metadata", ["1 remote Cable nil"])
        try await expectRows("SELECT * FROM watch_state", ["1 1 500 1 1800000000000"])
        try await expectRows("SELECT * FROM item_genre ORDER BY genre_id", ["1 11 local", "1 12 tmdb"])
        try await expectRows("SELECT * FROM occasion_phrase", ["3 Jolly"])
        try await expectRows("SELECT * FROM account_card", ["2 Robin kid nil"])
        try await expectState(["8 nil"])
        try await expectSearch("cab", [1])
        try await expectSearch("dish", [3])
        try await expectSearch("bunny", [])
    }

    func testAPassStoppedBetweenPagesResumesAtItsCursorAfterARestart() async throws {
        try adopt(version: 5, titles: ["Antenna"])
        let cursor = "p2+/="
        var failing = true
        changes { query in
            switch query {
            case "schema=1&since=5":
                return (.ok, SyncFixture.diff(version: 5, cursor: cursor, tables: [Self.movie(3, "Dish")]))
            case "schema=1&since=5&cursor=p2%2B%2F%3D":
                if failing { return (.internalServerError, Fixtures.error("internal")) }
                return (.ok, SyncFixture.diff(version: 8, tables: [Self.movie(4, "Eel")]))
            default: return nil
            }
        }

        do {
            try await engine().catchUp()
            XCTFail("the second page failed")
        } catch {}
        try await expectState(["5 \(cursor)"], "the watermark stays at since mid-pass")
        try await expectRows("SELECT id FROM item ORDER BY id", ["1", "3"])

        replica = nil
        failing = false
        let restarted = try fixture.open()
        try await engine(restarted).catchUp()

        XCTAssertEqual(queries.last, "schema=1&since=5&cursor=p2%2B%2F%3D")
        try await expectRows("SELECT id FROM item ORDER BY id", ["1", "3", "4"], in: restarted)
        try await expectState(["8 nil"], in: restarted)
    }

    static func movie(_ number: Int, _ title: String) -> SyncFixture.Table {
        .init("item", #"["id","kind","parsed_title"]"#, #"[[\#(id(number)),"movie","\#(title)"]]"#)
    }

    func testAPageNamingWhatTheReplicaLacksIsRefusedWhole() async throws {
        try adopt(version: 5, titles: ["Antenna"])
        let item = #"["id","kind","parsed_title"]"#
        let pages = [
            SyncFixture.diff(version: 8, tables: [Self.movie(3, "Dish"), .init("secret", #"["id"]"#, "[[\(id(1))]]")]),
            SyncFixture.diff(
                version: 8,
                tables: [.init("item", #"["id","kind","parsed_title","path"]"#, #"[[\#(id(3)),"movie","D","/x"]]"#)]),
            SyncFixture.diff(
                version: 8, tables: [Self.movie(3, "Dish"), .init("sync_state", #"["version"]"#, "[[99]]")]),
            SyncFixture.diff(
                version: 8, tables: [Self.movie(3, "Dish"), .init("item_shown", #"["item_id"]"#, "[[\(id(3))]]")]),
            SyncFixture.diff(version: 8, tables: [.init("item", #"["kind","parsed_title"]"#, #"[["movie","Dish"]]"#)]),
            SyncFixture.diff(
                version: 8, tables: [.init("item", #"["id","kind","parsed_title"]"#, #"[[\#(id(3)),"movie"]]"#)]),
            SyncFixture.diff(
                version: 8, tables: [Self.movie(3, "Dish")], tombstones: [("watch_state", "[[\(id(1))]]")]),
            SyncFixture.diff(version: 8, tables: [Self.movie(3, "Dish")], tombstones: [("action", "[[1]]")]),
            // An id cell that is not a canonical UUIDv7 string.
            SyncFixture.diff(
                version: 8, tables: [Self.movie(3, "Dish"), .init("item", item, #"[["ABC","movie","X"]]"#)]),
            SyncFixture.diff(version: 8, tables: [.init("item", item, #"[[4,"movie","X"]]"#)]),
            SyncFixture.diff(
                version: 8, tables: [Self.movie(3, "Dish")],
                tombstones: [("item", #"[["\#(UID.n(0xab).description.uppercased())"]]"#)]),
        ]
        for page in pages {
            changes { _ in (.ok, page) }

            do {
                try await engine().catchUp()
                XCTFail("applied \(page)")
            } catch {
                XCTAssertTrue(error is SyncEngine.Failure, "\(error)")
            }

            try await expectRows("SELECT id FROM item ORDER BY id", ["1"], page)
            try await expectState(["5 nil"], page)
        }
    }

    func testTheServerAskingForASnapshotMidLifeReplacesTheReplica() async throws {
        try adopt(version: 5, titles: ["Antenna"])
        try serve(version: 12, titles: ["Zed"])
        changes {
            $0 == "schema=1&since=5" ? (.ok, SyncFixture.mode("snapshot")) : (.ok, SyncFixture.diff(version: 12))
        }

        try await engine().catchUp()

        XCTAssertEqual(queries, ["schema=1&since=5", "schema=1&since=12"])
        try await expectRows("SELECT parsed_title FROM item", ["Zed"])
        try await expectState(["12 nil"])
        try await expectSearch("zed", [1])
    }

    func testAPageMeetingUnsentActionsIsDroppedUntilAFlushEmptiesTheQueue() async throws {
        try adopt(version: 5, titles: ["Antenna"])
        try await replica.write { try $0.execute(sql: ReplicaFixture.enqueue("a")) }
        changes { _ in (.ok, SyncFixture.diff(version: 8, tables: [Self.movie(3, "Dish")])) }
        let calls = calls
        let replica = replica!

        try await engine(flush: {
            await calls.flushed()
            if await calls.flushes == 2 { try await replica.write { try $0.execute(sql: "DELETE FROM queue.action") } }
        }).catchUp()

        let flushes = await calls.flushes
        XCTAssertEqual(flushes, 2)
        XCTAssertEqual(queries, ["schema=1&since=5", "schema=1&since=5"], "the dropped page is read again")
        try await expectRows("SELECT id FROM item ORDER BY id", ["1", "3"])
        try await expectState(["8 nil"])
    }

    func testAnUnsupportedClientStopsSyncingOnceAndKeepsItsReplica() async throws {
        let excluded = [
            SyncFixture.mode("unsupported", ranges: SyncFixture.ranges(schemaMax: 1)),
            SyncFixture.diff(
                version: 8, tables: [Self.movie(3, "Dish")],
                ranges: SyncFixture.ranges(apiMin: "0.27.0", apiMax: "1.0.0")),
            SyncFixture.diff(
                version: 8, tables: [Self.movie(3, "Dish")],
                ranges: SyncFixture.ranges(apiMin: "0.9.0", apiMax: "0.20.10")),
        ]
        for answer in excluded {
            try adopt(version: 5, titles: ["Antenna"])
            changes { _ in (.ok, answer) }
            let before = queries.count
            let engine = engine()
            XCTAssertFalse(engine.unsupported)

            try await engine.catchUp()
            try await engine.catchUp()

            XCTAssertTrue(engine.unsupported, answer)
            XCTAssertEqual(queries.count, before + 1, "asked once, then not again")
            try await expectRows("SELECT id FROM item ORDER BY id", ["1"], answer)
            try await expectState(["5 nil"])
        }
        let flushes = await calls.flushes
        XCTAssertEqual(flushes, excluded.count, "nothing is flushed once unsupported")
    }

    func testANewerServerWithinTheRangesStillSyncs() async throws {
        try adopt(version: 5, titles: ["Antenna"])
        changes { _ in
            (
                .ok,
                SyncFixture.diff(
                    version: 8, ranges: SyncFixture.ranges(apiMin: "0.9.2", apiMax: "0.104.0", schemaMax: 3))
            )
        }
        let engine = engine()

        try await engine.catchUp()

        XCTAssertFalse(engine.unsupported)
        try await expectState(["8 nil"])
    }

    func testAFailedSnapshotDownloadLeavesNothingBehind() async throws {
        changes { _ in (.ok, SyncFixture.mode("snapshot")) }
        transport.routes.routes["GET /sync/snapshot"] = (.internalServerError, Fixtures.error("internal"))

        do {
            try await engine().catchUp()
            XCTFail("the snapshot failed")
        } catch {}

        XCTAssertTrue(replica.isEmpty)
        XCTAssertEqual(try fixture.strays(), [])
    }
}

extension SyncEngineTests {
    func testIdStringsAreStoredAsBlobsThatJoinAndTheirTombstonesDeleteThem() async throws {
        try adopt(version: 5, titles: ["Antenna", "Bunny"])
        changes { _ in
            (
                .ok,
                SyncFixture.diff(
                    version: 8,
                    tables: [
                        .init(
                            "item", #"["id","kind","parsed_title","parent_id"]"#,
                            #"[[\#(id(3)),"season","S1",\#(id(1))]]"#),
                        .init(
                            "item_metadata", #"["item_id","source","title","overview"]"#,
                            #"[[\#(id(3)),"remote","Season",null]]"#),
                        .init(
                            "server_info", #"["id","name","metadata_source","metadata_mode"]"#,
                            #"[[1,"Den","tmdb","remote"]]"#),
                        .init("account", #"["id","kind","name","has_pin"]"#, #"[[\#(id(4)),"kid","Robin",1]]"#),
                    ],
                    tombstones: [("item", "[[\(id(2))]]")])
            )
        }

        try await engine().catchUp()

        try await expectRows(
            "SELECT typeof(id), length(id), typeof(parent_id) FROM item WHERE parsed_title = 'S1'", ["blob 16 blob"])
        try await expectRows(
            """
            SELECT c.parsed_title, p.parsed_title, s.title FROM item c JOIN item p ON p.id = c.parent_id
            JOIN item_shown s ON s.item_id = c.id
            """, ["S1 Antenna Season"], "the row joins its parent and its metadata")
        try await expectRows("SELECT id FROM item ORDER BY id", ["1", "3"], "the string key deletes the blob row")
        try await expectRows("SELECT id, typeof(id), name FROM server_info", ["1 integer Den"], "an integer key")
        try await expectRows("SELECT typeof(has_pin) FROM account", ["integer"], "an untyped column")
        try await expectState(["8 nil"])
    }
}
