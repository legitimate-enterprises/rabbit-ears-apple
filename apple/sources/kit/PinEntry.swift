/// The four PIN dots: digits typed so far, never shown.
public struct PinEntry: Equatable, Sendable {
    public static let length = 4
    public private(set) var digits = ""

    public init() {}

    /// Adds a digit; true once the PIN is complete and ready to submit.
    public mutating func type(_ character: Character) -> Bool {
        guard character.isASCII, character.isNumber, digits.count < Self.length else { return false }
        digits.append(character)
        return digits.count == Self.length
    }

    public mutating func deleteBackward() {
        if !digits.isEmpty { digits.removeLast() }
    }

    public mutating func clear() { digits = "" }

    public var accessibilityLabel: String { "PIN, \(digits.count) of \(Self.length) digits entered" }
}
