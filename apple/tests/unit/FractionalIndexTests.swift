import XCTest

@testable import RabbitEarsKit

final class FractionalIndexTests: XCTestCase {
    private func key(_ lower: String?, _ upper: String?) throws -> String {
        try FractionalIndex.key(between: lower, and: upper)
    }

    // Vectors from rocicorp/fractional-indexing src/test.js; the server's Go port must agree on every one.
    func testExactKeys() throws {
        let vectors: [((String?, String?), String)] = [
            ((nil, nil), "a0"),
            ((nil, "a0"), "Zz"),
            ((nil, "Zz"), "Zy"),
            (("a0", nil), "a1"),
            (("a1", nil), "a2"),
            (("a0", "a1"), "a0V"),
            (("a1", "a2"), "a1V"),
            (("a0V", "a1"), "a0l"),
            (("Zz", "a0"), "ZzV"),
            (("Zz", "a1"), "a0"),
            ((nil, "Y00"), "Xzzz"),
            (("bzz", nil), "c000"),
            (("a0", "a0V"), "a0G"),
            (("a0", "a0G"), "a08"),
            (("b125", "b129"), "b127"),
            (("a0", "a1V"), "a1"),
            (("Zz", "a01"), "a0"),
            ((nil, "a0V"), "a0"),
            ((nil, "b999"), "b99"),
            ((nil, "A000000000000000000000000001"), "A000000000000000000000000000V"),
            (("zzzzzzzzzzzzzzzzzzzzzzzzzzy", nil), "zzzzzzzzzzzzzzzzzzzzzzzzzzz"),
            (("zzzzzzzzzzzzzzzzzzzzzzzzzzz", nil), "zzzzzzzzzzzzzzzzzzzzzzzzzzzV"),
            (("a1", "a0"), "a0V"),
        ]
        for ((lower, upper), expected) in vectors {
            XCTAssertEqual(try key(lower, upper), expected, "\(lower ?? "nil"), \(upper ?? "nil")")
        }
    }

    func testInvalidInput() {
        let cases: [((String?, String?), FractionalIndexError)] = [
            ((nil, "A00000000000000000000000000"), .invalidKey("A00000000000000000000000000")),
            (("a00", nil), .invalidKey("a00")),
            (("a00", "a1"), .invalidKey("a00")),
            (("0", "1"), .invalidHead("0")),
            (("a0", "a0"), .outOfOrder("", "")),
            (("a0\u{e9}", nil), .invalidKey("a0\u{e9}")),
        ]
        for ((lower, upper), expected) in cases {
            XCTAssertThrowsError(try key(lower, upper)) { XCTAssertEqual($0 as? FractionalIndexError, expected) }
        }
    }

    func testKeysBetween() throws {
        XCTAssertEqual(try FractionalIndex.keys(between: nil, and: nil, count: 5), ["a0", "a1", "a2", "a3", "a4"])
        XCTAssertEqual(try FractionalIndex.keys(between: "a0", and: nil, count: 3), ["a1", "a2", "a3"])
        XCTAssertEqual(try FractionalIndex.keys(between: nil, and: "a1", count: 2), ["Zz", "a0"])
        XCTAssertEqual(try FractionalIndex.keys(between: "a0", and: "a1", count: 3), ["a0G", "a0V", "a0l"])
        XCTAssertEqual(try FractionalIndex.keys(between: "a0", and: "a1", count: 0), [])
    }

    // Outputs of the server's Go port for the same inputs.
    func testKeysMatchServer() throws {
        XCTAssertEqual(try key("az", "b00"), "azV")
        let five = try FractionalIndex.keys(between: "a0", and: "a1", count: 5)
        XCTAssertEqual(five, ["a08", "a0G", "a0V", "a0d", "a0l"])
        XCTAssertEqual(try FractionalIndex.keys(between: nil, and: nil, count: 5), ["a0", "a1", "a2", "a3", "a4"])
        XCTAssertEqual(try FractionalIndex.keys(between: "a5", and: "a0", count: 3), ["a2", "a1", "a0V"])
    }

    func testNegativeCountThrows() {
        for (lower, upper) in [(nil, nil), ("a0", nil), (nil, "a1"), ("a0", "a5")] as [(String?, String?)] {
            XCTAssertThrowsError(try FractionalIndex.keys(between: lower, and: upper, count: -1)) {
                XCTAssertEqual($0 as? FractionalIndexError, .negativeCount(-1))
            }
        }
    }

    // Order is judged on UTF-8 bytes, as SQLite's BINARY collation does.
    private func assertBetween(_ result: String, _ lower: String?, _ upper: String?) {
        let bytes = Array(result.utf8)
        if let lower { XCTAssertTrue(Array(lower.utf8).lexicographicallyPrecedes(bytes), "\(lower) < \(result)") }
        if let upper { XCTAssertTrue(bytes.lexicographicallyPrecedes(Array(upper.utf8)), "\(result) < \(upper)") }
    }

    func testRepeatedInsertAtFront() throws {
        var first = try key(nil, nil)
        for _ in 0..<200 {
            let result = try key(nil, first)
            assertBetween(result, nil, first)
            first = result
        }
    }

    func testRepeatedInsertAtBack() throws {
        var last = try key(nil, nil)
        for _ in 0..<200 {
            let result = try key(last, nil)
            assertBetween(result, last, nil)
            last = result
        }
    }

    func testRepeatedInsertBetweenAdjacentKeys() throws {
        let lower = "a0"
        var upper = "a1"
        for _ in 0..<200 {
            let result = try key(lower, upper)
            assertBetween(result, lower, upper)
            upper = result
        }
        var low = "a0"
        for _ in 0..<200 {
            let result = try key(low, "a1")
            assertBetween(result, low, "a1")
            low = result
        }
    }

    func testRandomInsertsStaySorted() throws {
        var seed: UInt64 = 1
        var list: [String] = []
        for _ in 0..<1000 {
            seed = (seed &* 1_103_515_245 &+ 12345) & 0x7fff_ffff
            let pos = Int(seed % UInt64(list.count + 1))
            let lower = pos > 0 ? list[pos - 1] : nil
            let upper = pos < list.count ? list[pos] : nil
            let result = try key(lower, upper)
            assertBetween(result, lower, upper)
            list.insert(result, at: pos)
        }
        XCTAssertEqual(list, list.sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) })
    }
}
