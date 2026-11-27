import Foundation
import GRDB
import XCTest

// The replica runs SQL the server ships, so it must run on the server's own
// SQLite build (modernc.org/sqlite's), never the system's.
final class BundledSQLiteTests: XCTestCase {
    func testSQLiteIsTheServersBuildNotTheSystems() throws {
        try DatabaseQueue().read { db in
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT sqlite_version()"), "3.54.1")
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT sqlite_source_id()"),
                "2026-10-16 14:45:20 555e07ef33f69a0957d24d8e555b702464a131d6f1607f4c3c1e4551e8e6ca76")
        }
    }

    func testSQLiteHasTheServersBehaviorAffectingOptions() throws {
        let options = try DatabaseQueue().read { db in
            Set(try String.fetchAll(db, sql: "PRAGMA compile_options"))
        }
        let expected: Set = [
            "ENABLE_COLUMN_METADATA", "ENABLE_DBPAGE_VTAB", "ENABLE_DBSTAT_VTAB", "ENABLE_FTS5",
            "ENABLE_GEOPOLY", "ENABLE_MATH_FUNCTIONS", "ENABLE_OFFSET_SQL_FUNC",
            "ENABLE_PREUPDATE_HOOK", "ENABLE_RTREE", "ENABLE_SNAPSHOT", "ENABLE_STAT4",
            "LIKE_DOESNT_MATCH_BLOBS", "SOUNDEX",
        ]
        XCTAssertEqual(expected.subtracting(options), [])
    }

    func testFullTextSearchMatchesOnlyTheRowsWithTheTerm() throws {
        let titles = try DatabaseQueue().write { db in
            try db.execute(
                sql: """
                    CREATE VIRTUAL TABLE titles USING fts5(name);
                    INSERT INTO titles(name) VALUES ('Rabbit Ears'), ('Bunny Hop');
                    """)
            return try String.fetchAll(db, sql: "SELECT name FROM titles WHERE titles MATCH 'ears'")
        }
        XCTAssertEqual(titles, ["Rabbit Ears"])
    }

    func testAnAttachedDatabaseFileIsQueryable() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let other = dir.appending(path: "other.sqlite").path
        try DatabaseQueue(path: other).write { db in
            try db.execute(sql: "CREATE TABLE shows(name TEXT); INSERT INTO shows VALUES ('Antenna')")
        }

        // ATTACH is refused inside a transaction, which write { } opens.
        let names = try DatabaseQueue(path: dir.appending(path: "main.sqlite").path).inDatabase { db in
            try db.execute(sql: "ATTACH DATABASE ? AS other", arguments: [other])
            return try String.fetchAll(db, sql: "SELECT name FROM other.shows")
        }
        XCTAssertEqual(names, ["Antenna"])
    }
}
