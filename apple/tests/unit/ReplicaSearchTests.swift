import GRDB
import RabbitEarsAPI
import XCTest

@testable import RabbitEarsKit

final class ReplicaSearchTests: XCTestCase {
    private var db: DatabaseQueue!

    override func setUpWithError() throws {
        db = try DatabaseQueue()
        try db.write { try $0.execute(sql: SyncFixture.schema) }
    }

    private func item(
        _ id: UID, _ kind: String, _ parsed: String, shown: String? = nil, season: Int? = nil, episode: Int? = nil
    ) throws {
        try db.write { db in
            try db.execute(
                sql: "INSERT INTO item(id, kind, parsed_title, season_number, episode_number) VALUES (?, ?, ?, ?, ?)",
                arguments: [id, kind, parsed, season, episode])
            if let shown {
                try db.execute(
                    sql: "INSERT INTO item_metadata(item_id, source, title) VALUES (?, 'remote', ?)",
                    arguments: [id, shown])
            }
        }
    }

    private func build() throws { try db.write(ReplicaSearch.build) }

    private func items(_ query: String) throws -> [UID] {
        try db.read { try ReplicaSearch.items(matching: query, in: $0) }
    }

    func testAnyPartOfATitleMatchesAndTitlesStartingWithTheQueryComeFirst() throws {
        try item(1, "movie", "The Antenna")
        try item(2, "movie", "antenna two")
        try item(3, "show", "Bunny")
        try item(4, "movie", "Zebra", shown: "Antenna Rising")
        try item(5, "movie", "Ant Farm")
        try item(6, "movie", "Plantation")
        try build()

        XCTAssertEqual(try items("ant"), [5, 2, 4, 6, 1], "prefixes by title, then the rest by title")
        XCTAssertEqual(try items("tenn"), [2, 1, 4])
        XCTAssertEqual(try items("unn"), [3])
    }

    func testMatchingIgnoresCase() throws {
        try item(1, "movie", "Antenna")
        try item(2, "show", "Bunny", shown: "WAVELENGTH")
        try build()

        XCTAssertEqual(try items("ANTENNA"), [1])
        XCTAssertEqual(try items("wavel"), [2])
    }

    func testAQueryShorterThanThreeCharactersStillFindsSubstrings() throws {
        try item(1, "movie", "Antenna")
        try item(2, "movie", "Xen")
        try item(3, "movie", "Bunny")
        try build()

        XCTAssertEqual(try items("en"), [1, 2])
        XCTAssertEqual(try items("X"), [2])
    }

    func testEpisodesMatchByShownTitleOnlyAndOtherKindsNever() throws {
        try item(1, "episode", "Antenna", shown: "Pilot", season: 1, episode: 2)
        try item(2, "episode", "Antenna", shown: "Pilot Light", season: 1, episode: 1)
        try item(3, "season", "Pilot Season")
        try item(4, "song", "Pilot Song")
        try build()

        XCTAssertEqual(try items("Antenna"), [])
        XCTAssertEqual(try items("pilot"), [2, 1], "by title, then season and episode")
    }

    func testPeopleMatchByNameWithPrefixesFirst() throws {
        try db.write { db in
            try db.execute(
                sql: "INSERT INTO person(id, name) VALUES (?, 'Sam Antonio'), (?, 'antonia'), (?, 'Bo')",
                arguments: [UID.n(1), UID.n(2), UID.n(3)])
        }
        try build()

        let people = try db.read { try ReplicaSearch.people(matching: "anto", in: $0) }
        XCTAssertEqual(people, [2, 1])
    }

    func testUpdateReindexesChangedAndDeletedRows() throws {
        try item(1, "movie", "Antenna")
        try item(2, "movie", "Bunny")
        try db.write { try $0.execute(sql: "INSERT INTO person(id, name) VALUES (\(sqlID(7)), 'Sam')") }
        try build()
        try db.write { db in
            try db.execute(sql: "UPDATE item SET parsed_title = 'Cable' WHERE id = \(sqlID(1))")
            try db.execute(
                sql: "INSERT INTO item_metadata(item_id, source, title) VALUES (?, 'remote', 'Cabled')",
                arguments: [UID.n(2)])
            try db.execute(sql: "INSERT INTO item(id, kind, parsed_title) VALUES (\(sqlID(3)), 'movie', 'Cables')")
            try db.execute(sql: "UPDATE person SET name = 'Robin' WHERE id = \(sqlID(7))")
        }
        XCTAssertEqual(try items("cab"), [], "the index, not the tables, finds candidates")

        try db.write { db in
            try db.execute(sql: "DELETE FROM item WHERE id = \(sqlID(3))")
            try ReplicaSearch.update(
                in: db,
                changed: [
                    "item": [UID.n(1).databaseValue, UID.n(3).databaseValue],
                    "item_metadata": [UID.n(2).databaseValue], "person": [UID.n(7).databaseValue],
                ])
        }

        XCTAssertEqual(try items("cab"), [2, 1])
        XCTAssertEqual(try items("ant"), [])
        XCTAssertEqual(try db.read { try ReplicaSearch.people(matching: "rob", in: $0) }, [7])
    }

    func testOneApplyReindexesMoreChangedRowsThanOneStatementTakes() throws {
        let ids = (1...1_200).map(UID.n)
        try db.write { db in
            for id in ids {
                try db.execute(
                    sql: "INSERT INTO item(id, kind, parsed_title) VALUES (?, 'movie', 'Antenna')", arguments: [id])
            }
            try ReplicaSearch.build(in: db)
            try db.execute(sql: "UPDATE item SET parsed_title = 'Cable'")
            try ReplicaSearch.update(in: db, changed: ["item": ids.map(\.databaseValue)])
        }

        XCTAssertEqual(try items("cable").count, 1_200)
        XCTAssertEqual(try items("antenna"), [])
    }

    func testAChangedServerSettingReindexesEveryTitle() throws {
        try item(1, "movie", "Antenna", shown: "Cable")
        try build()
        try db.write { try $0.execute(sql: "UPDATE server_info SET metadata_mode = 'local'") }

        try db.write { try ReplicaSearch.update(in: $0, changed: ["server_info": [1.databaseValue]]) }

        XCTAssertEqual(try items("cable"), [], "item_shown no longer shows the remote title")
        XCTAssertEqual(try items("antenna"), [1])
    }
}
