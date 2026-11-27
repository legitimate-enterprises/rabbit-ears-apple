import Foundation
import GRDB
import RabbitEarsAPI
import XCTest

@testable import RabbitEarsKit

final class UIDTests: XCTestCase {
    func testNewIdsStrictlyIncrease() {
        let ids = (0..<10_000).map { _ in UID.new() }
        for (earlier, later) in zip(ids, ids.dropFirst()) {
            XCTAssertLessThan(earlier, later)
            XCTAssertLessThan(earlier.description, later.description)
        }
    }

    func testANewIdIsAVersion7UUIDOfNow() throws {
        let id = UID.new()
        let text = Array(id.description)
        XCTAssertEqual(text.count, 36)
        XCTAssertEqual(text[14], "7")
        XCTAssertTrue("89ab".contains(text[19]), id.description)
        let ms = withUnsafeBytes(of: id.uuid.uuid) { $0.prefix(6).reduce(UInt64(0)) { $0 << 8 | UInt64($1) } }
        XCTAssertEqual(Double(ms), Date().timeIntervalSince1970 * 1000, accuracy: 1000)
    }

    func testAClockSetBackStillMakesALaterId() {
        let first = UID.new()
        XCTAssertLessThan(first, UID.new(at: Date().addingTimeInterval(-5)))
    }

    func testOnlyTheCanonicalFormParses() throws {
        let id = UID.new()
        XCTAssertEqual(UID(id.description), id)
        XCTAssertNil(UID(id.description.uppercased()))
        XCTAssertNil(UID(UUID().uuidString.lowercased()), "version 4")
        XCTAssertNil(UID("{\(id)}"))
        XCTAssertNil(UID(id.description.replacingOccurrences(of: "-", with: "")))
        XCTAssertNil(UID("00000000-0000-7000-c000-000000000001"), "variant 110x")
        XCTAssertEqual(UID("00000000-0000-7000-8000-00000000002a"), UID.n(42))
    }

    func testOrderIsBytewise() {
        XCTAssertLessThan(UID.n(1), UID.n(2))
        XCTAssertLessThan(UID.n(0xff), UID.n(0x100))
        XCTAssertLessThan(UID.n(1 << 40), UID.new())
    }

    func testJSONIsTheLowercaseString() throws {
        let id = UID.new()
        XCTAssertEqual(String(bytes: try JSONEncoder().encode(id), encoding: .utf8), "\"\(id)\"")
        XCTAssertEqual(try JSONDecoder().decode(UID.self, from: Data("\"\(id)\"".utf8)), id)
        XCTAssertThrowsError(try JSONDecoder().decode(UID.self, from: Data("\"\(id.description.uppercased())\"".utf8)))
        XCTAssertThrowsError(try JSONDecoder().decode(UID.self, from: Data("7".utf8)))
    }

    func testADictionaryKeyedByIdEncodesAsAnObject() throws {
        let encoded = try JSONEncoder().encode([UID.n(3): 1])
        XCTAssertEqual(String(bytes: encoded, encoding: .utf8), #"{"00000000-0000-7000-8000-000000000003":1}"#)
        XCTAssertEqual(try JSONDecoder().decode([UID: Int].self, from: encoded), [UID.n(3): 1])
    }

    func testAnIdIsASixteenByteBlobInTheDatabase() throws {
        let db = try DatabaseQueue()
        let id = UID.new()
        try db.write { db in
            try db.execute(sql: "CREATE TABLE t (id, n)")
            try db.execute(sql: "INSERT INTO t VALUES (?, 1), (?, 2)", arguments: [id, id.description])
        }
        try db.read { db in
            let stored = try Row.fetchOne(db, sql: "SELECT typeof(id), length(id), id FROM t WHERE n = 1")
            XCTAssertEqual(stored?[0], "blob")
            XCTAssertEqual(stored?[1], 16)
            XCTAssertEqual(stored?[2] as UID?, id)
            XCTAssertNil(UID.fromDatabaseValue(id.description.databaseValue), "a TEXT id is no id")
            XCTAssertNil(UID.fromDatabaseValue(7.databaseValue))
            XCTAssertThrowsError(try UID.fetchOne(db, sql: "SELECT id FROM t WHERE n = 2"), "a TEXT id fails its read")
            XCTAssertNil(try UID.fetchOne(db, sql: "SELECT NULL"))
        }
    }

    func testTestIdsAreTheServersAndSQLNamesThem() throws {
        let one: UID = 1
        XCTAssertEqual(one.description, "00000000-0000-7000-8000-000000000001")
        XCTAssertEqual(sqlID(0x2a), "x'0000000000007000800000000000002a'")
        let db = try DatabaseQueue()
        XCTAssertEqual(try db.read { try UID.fetchOne($0, sql: "SELECT \(sqlID(42))") }, UID.n(42))
    }
}
