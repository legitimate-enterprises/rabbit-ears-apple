import RabbitEarsAPI
import SwiftUI

/// An occasion's three colors as radial glows over the plain background, drawn as OccasionWash in the
/// API spec says every client draws them. It fills the space it is given, so a screen sets it behind its
/// content, out of the scroll. Static; with anything but three valid colors it draws nothing, so the
/// background shows as is.
public struct OccasionWash: View {
    struct Channels {
        let red: Double
        let green: Double
        let blue: Double
    }

    struct Glow {
        let color: Channels
        let center: UnitPoint
        let stops: [(opacity: Double, location: Double)]
    }

    /// Where colors 1, 2 and 3 glow: a triangle pointing down. Pointing up is
    /// `[.bottomLeading, .top, .bottomTrailing]`.
    static let centers: [UnitPoint] = [.topLeading, .bottom, .topTrailing]
    /// Each color's peak opacity at a strength of 100.
    static let base = [0.24, 0.30, 0.24]

    private let glows: [Glow]?
    private let reach: Int

    public init(colors: [String]?, wash: Components.Schemas.OccasionWash) {
        glows = Self.palette(colors).map { Self.glows($0, wash) }
        reach = wash.reach
    }

    public var body: some View {
        if let glows {
            GeometryReader { geometry in
                let radius = Self.radius(in: geometry.size, reach: reach)
                // The middle glow is drawn over the corners'.
                ZStack {
                    ForEach([0, 2, 1], id: \.self) { index in
                        let glow = glows[index]
                        let color = Color(red: glow.color.red, green: glow.color.green, blue: glow.color.blue)
                        RadialGradient(
                            stops: glow.stops.map { .init(color: color.opacity($0.opacity), location: $0.location) },
                            center: glow.center, startRadius: 0, endRadius: radius)
                    }
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    nonisolated static func glows(_ palette: [Channels], _ wash: Components.Schemas.OccasionWash) -> [Glow] {
        let bright = Double(wash.brightness) / 100
        let sharp = Double(wash.sharpness) / 100
        return palette.enumerated().map { index, color in
            let lift = { (channel: Double) in channel * (1 - bright) + bright }
            let peak = min(1, base[index] * Double(wash.strength) / 100)
            return Glow(
                color: Channels(red: lift(color.red), green: lift(color.green), blue: lift(color.blue)),
                center: centers[index],
                stops: [(peak, 0), (peak, sharp), (0.4 * peak, sharp + (1 - sharp) / 2), (0, 1)])
        }
    }

    nonisolated static func radius(in size: CGSize, reach: Int) -> CGFloat {
        max(size.width * 0.8, size.height * 0.5) * CGFloat(reach) / 100
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
