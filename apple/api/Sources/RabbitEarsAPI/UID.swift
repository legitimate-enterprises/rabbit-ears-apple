import Foundation

/// A row id: a UUIDv7, written as its canonical lowercase string in JSON,
/// paths and queries. The spec's `Id` is this type.
public struct UID: Hashable, Comparable, Sendable, Codable, LosslessStringConvertible, CodingKeyRepresentable {
    public let uuid: UUID

    public init(uuid: UUID) { self.uuid = uuid }

    /// Only the spec's pattern: lowercase hex, dashes at 8, 13, 18 and 23,
    /// version 7, variant 10xx.
    public init?(_ text: String) {
        let chars = Array(text.utf8)
        guard chars.count == 36 else { return nil }
        for (i, c) in chars.enumerated() {
            switch i {
            case 8, 13, 18, 23: guard c == UInt8(ascii: "-") else { return nil }
            case 14: guard c == UInt8(ascii: "7") else { return nil }
            case 19: guard Array("89ab".utf8).contains(c) else { return nil }
            default: guard Array("0123456789abcdef".utf8).contains(c) else { return nil }
            }
        }
        guard let uuid = UUID(uuidString: text) else { return nil }
        self.uuid = uuid
    }

    public var description: String { uuid.uuidString.lowercased() }

    /// After every id this process made before, also when the wall clock steps back.
    public static func new() -> UID { clock.next(Date()) }

    /// `new()` at the instant `now`, after every earlier id all the same.
    public static func new(at now: Date) -> UID { clock.next(now) }

    /// Bytewise, as the server orders ids.
    public static func < (a: UID, b: UID) -> Bool {
        withUnsafeBytes(of: a.uuid.uuid) { a in
            withUnsafeBytes(of: b.uuid.uuid) { b in a.lexicographicallyPrecedes(b) }
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let id = UID(text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "id \(text)"))
        }
        self = id
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }

    /// A dictionary keyed by id encodes as a JSON object keyed by the id's string.
    public var codingKey: any CodingKey { description.codingKey }

    public init?<T: CodingKey>(codingKey: T) { self.init(codingKey.stringValue) }

    private static let clock = Clock()

    /// Unix milliseconds in the 48-bit time field and a 12-bit counter in
    /// rand_a, together kept strictly increasing.
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        /// (unix ms << 12) | counter, of the last id made.
        private var last: UInt64 = 0

        func next(_ now: Date) -> UID {
            let ms = UInt64(max(0, (now.timeIntervalSince1970 * 1000).rounded(.down)))
            lock.lock()
            last = max(ms << 12, last + 1)
            let stamp = last
            lock.unlock()
            var b = (0..<16).map { _ in UInt8.random(in: 0...255) }
            for i in 0..<6 { b[i] = UInt8(truncatingIfNeeded: stamp >> (12 + 8 * (5 - i))) }
            b[6] = 0x70 | UInt8((stamp >> 8) & 0x0F)
            b[7] = UInt8(truncatingIfNeeded: stamp)
            b[8] = 0x80 | (b[8] & 0x3F)
            return UID(
                uuid: UUID(
                    uuid: (
                        b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14],
                        b[15]
                    )))
        }
    }
}
