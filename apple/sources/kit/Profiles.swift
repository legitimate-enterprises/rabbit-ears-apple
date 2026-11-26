import Foundation
import RabbitEarsAPI

/// The server's eight profile colors. A profile wears the one the server
/// gives it; cast and crew without a headshot take one by id.
public enum ProfilePalette {
    public static let colors = [
        "#3C4170", "#2E6B5B", "#6B3A2E", "#5B4A8A", "#8A5A2B", "#2E5B8A", "#6B2E5A", "#4A6B2E",
    ]

    /// `#RRGGBB` as 0xRRGGBB; nil for anything else.
    public static func rgb(_ hex: String) -> UInt32? {
        guard hex.count == 7, hex.first == "#" else { return nil }
        return UInt32(hex.dropFirst(), radix: 16)
    }

    /// Stable per id, so a person keeps their placeholder everywhere.
    public static func placeholder(_ id: Int64) -> UInt32 {
        rgb(colors[Int(id.magnitude % UInt64(colors.count))]) ?? 0
    }
}

extension Account {
    /// The server's color for this profile; the first stands in for none.
    public var rgb: UInt32 { color.flatMap(ProfilePalette.rgb) ?? ProfilePalette.placeholder(0) }
}
