/// Port of rocicorp/fractional-indexing `generateKeyBetween` (commit 648d2e6) with its default alphabets. The
/// server's Go port (roci.dev/fracdex) must return identical keys for identical inputs.
enum FractionalIndexError: Error, Equatable {
    case invalidKey(String)
    case invalidHead(String)
    case outOfOrder(String, String)
    case trailingZero
    case exhausted
    case negativeCount(Int)
}

enum FractionalIndex {
    // Ascending byte order, so keys compare correctly under SQLite's BINARY collation.
    private static let digits = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz".utf8)
    // Integer-part heads: A-Z give lengths 27...2, a-z give lengths 2...27.
    private static let heads = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz".utf8)

    static func key(between lower: String?, and upper: String?) throws -> String {
        var lower = lower.map { Array($0.utf8) }
        var upper = upper.map { Array($0.utf8) }
        if let lower { try validate(lower) }
        if let upper { try validate(upper) }
        // Upstream accepts either order and swaps.
        if let low = lower, let high = upper, low.lexicographicallyPrecedes(high) == false, low != high {
            lower = high
            upper = low
        }
        return String(bytes: try between(lower, upper), encoding: .utf8) ?? ""
    }

    static func keys(between lower: String?, and upper: String?, count: Int) throws -> [String] {
        guard count >= 0 else { throw FractionalIndexError.negativeCount(count) }
        if count == 0 { return [] }
        if count == 1 { return [try key(between: lower, and: upper)] }
        if upper == nil {
            var mid = try key(between: lower, and: upper)
            var result = [mid]
            for _ in 1..<count {
                mid = try key(between: mid, and: upper)
                result.append(mid)
            }
            return result
        }
        if lower == nil {
            var mid = try key(between: lower, and: upper)
            var result = [mid]
            for _ in 1..<count {
                mid = try key(between: lower, and: mid)
                result.append(mid)
            }
            return result.reversed()
        }
        let half = count / 2
        let pivot = try key(between: lower, and: upper)
        return try keys(between: lower, and: pivot, count: half) + [pivot]
            + keys(between: pivot, and: upper, count: count - half - 1)
    }

    private static func between(_ lower: [UInt8]?, _ upper: [UInt8]?) throws -> [UInt8] {
        guard let lower else {
            guard let upper else { return [heads[26], digits[0]] }
            let ib = try integerPart(upper)
            let fb = Array(upper[ib.count...])
            if ib == smallestInteger { return ib + (try midpoint([], fb)) }
            if ib.lexicographicallyPrecedes(upper) { return ib }
            guard let decremented = try decrement(ib) else { throw FractionalIndexError.exhausted }
            return decremented
        }
        guard let upper else {
            let ia = try integerPart(lower)
            if let incremented = try increment(ia) { return incremented }
            return ia + (try midpoint(Array(lower[ia.count...]), nil))
        }
        let ia = try integerPart(lower)
        let fa = Array(lower[ia.count...])
        let ib = try integerPart(upper)
        let fb = Array(upper[ib.count...])
        if ia == ib { return ia + (try midpoint(fa, fb)) }
        guard let index = try increment(ia) else { throw FractionalIndexError.exhausted }
        if index.lexicographicallyPrecedes(upper) { return index }
        return ia + (try midpoint(fa, nil))
    }

    // `lower` may be empty and `upper` is nil or non-empty; neither may end in the zero digit.
    private static func midpoint(_ lower: [UInt8], _ upper: [UInt8]?) throws -> [UInt8] {
        let zero = digits[0]
        if let upper, !lower.lexicographicallyPrecedes(upper) {
            throw FractionalIndexError.outOfOrder(string(lower), string(upper))
        }
        if lower.last == zero || upper?.last == zero { throw FractionalIndexError.trailingZero }
        if let upper, !upper.isEmpty {
            var common = 0
            while common < upper.count, (common < lower.count ? lower[common] : zero) == upper[common] {
                common += 1
            }
            if common > 0 {
                return Array(upper[..<common])
                    + (try midpoint(Array(lower.dropFirst(common)), Array(upper[common...])))
            }
        }
        let digitA = lower.first.map(digitValue) ?? 0
        let digitB = upper.map { digitValue($0[0]) } ?? digits.count
        if digitB - digitA > 1 {
            // Matches JS Math.round for the non-negative half-integers that arise here.
            return [digits[(digitA + digitB + 1) / 2]]
        }
        if let upper, upper.count > 1 { return [upper[0]] }
        return [digits[digitA]] + (try midpoint(Array(lower.dropFirst()), nil))
    }

    private static var smallestInteger: [UInt8] { [heads[0]] + Array(repeating: digits[0], count: heads.count / 2) }

    private static func digitValue(_ byte: UInt8) -> Int { digits.firstIndex(of: byte) ?? 0 }

    private static func string(_ bytes: [UInt8]) -> String { String(bytes: bytes, encoding: .utf8) ?? "" }

    private static func integerLength(head: UInt8) throws -> Int {
        guard let index = heads.firstIndex(of: head) else { throw FractionalIndexError.invalidHead(string([head])) }
        let half = heads.count / 2
        return index < half ? half - index + 1 : index - half + 2
    }

    private static func integerPart(_ key: [UInt8]) throws -> [UInt8] {
        let length = try integerLength(head: key[0])
        guard length <= key.count else { throw FractionalIndexError.invalidKey(string(key)) }
        return Array(key[..<length])
    }

    // The fractional part is checked as well so a stray byte cannot silently read as the zero digit.
    private static func validate(_ key: [UInt8]) throws {
        let invalid = FractionalIndexError.invalidKey(string(key))
        guard !key.isEmpty else { throw invalid }
        if key == smallestInteger { throw invalid }
        let integer = try integerPart(key)
        if key.dropFirst().contains(where: { !digits.contains($0) }) { throw invalid }
        if key.count > integer.count, key.last == digits[0] { throw invalid }
    }

    // nil when `integer` is the largest integer.
    private static func increment(_ integer: [UInt8]) throws -> [UInt8]? {
        try step(integer, by: 1, carry: digits[0], limit: digits.count)
    }

    // nil when `integer` is the smallest integer.
    private static func decrement(_ integer: [UInt8]) throws -> [UInt8]? {
        try step(integer, by: -1, carry: digits[digits.count - 1], limit: -1)
    }

    private static func step(_ integer: [UInt8], by delta: Int, carry: UInt8, limit: Int) throws -> [UInt8]? {
        let head = integer[0]
        var trailing: [UInt8] = []
        for index in stride(from: integer.count - 1, through: 1, by: -1) {
            let value = digitValue(integer[index]) + delta
            if value == limit {
                trailing.insert(carry, at: 0)
            } else {
                return [head] + integer[1..<index] + [digits[value]] + trailing
            }
        }
        let headIndex = heads.firstIndex(of: head)!
        let next = headIndex + delta
        guard heads.indices.contains(next) else { return nil }
        let newHead = heads[next]
        let lengthDelta = try integerLength(head: newHead) - integerLength(head: head)
        if lengthDelta > 0 { return [newHead] + trailing + [carry] }
        if lengthDelta < 0 { return [newHead] + trailing.dropFirst() }
        return [newHead] + trailing
    }
}
