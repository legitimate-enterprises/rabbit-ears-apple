import SwiftUI

/// A soft wash of an occasion's three colours over the plain background: one very large,
/// blurred spot each at the top corners and top edge, fading out below the first rows.
/// Static; with anything but three valid colours it draws nothing, so the background shows as is.
public struct OccasionWash: View {
    struct Channels {
        let red: Double
        let green: Double
        let blue: Double
    }

    private let palette: [Channels]?

    public init(colors: [String]?) { palette = Self.palette(colors) }

    public var body: some View {
        if let palette {
            let spots = palette.map { Color(red: $0.red, green: $0.green, blue: $0.blue) }
            GeometryReader { geometry in
                let radius = max(geometry.size.width * 0.8, geometry.size.height * 0.5)
                ZStack {
                    spot(spots[0], at: .topLeading, strength: 0.24, radius: radius)
                    spot(spots[1], at: .top, strength: 0.30, radius: radius)
                    spot(spots[2], at: .topTrailing, strength: 0.24, radius: radius)
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    private func spot(_ color: Color, at center: UnitPoint, strength: Double, radius: CGFloat) -> some View {
        RadialGradient(
            colors: [color.opacity(strength), color.opacity(strength * 0.4), .clear],
            center: center, startRadius: 0, endRadius: radius)
    }

    nonisolated static func palette(_ hex: [String]?) -> [Channels]? {
        guard let hex, hex.count == 3 else { return nil }
        let colors = hex.compactMap(rgb)
        return colors.count == 3 ? colors : nil
    }

    /// `#RRGGBB`, nothing looser.
    nonisolated static func rgb(_ hex: String) -> Channels? {
        let digits = hex.dropFirst()
        guard hex.first == "#", digits.count == 6, digits.allSatisfy(\.isHexDigit),
            let value = UInt32(digits, radix: 16)
        else { return nil }
        return Channels(
            red: Double(value >> 16 & 0xFF) / 255, green: Double(value >> 8 & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255)
    }
}
