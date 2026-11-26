import SwiftUI

/// A kind's symbol, drawn over a tile's flat color until its image arrives.
public struct PlaceholderGlyph: View {
    let kind: PlaceholderKind
    let side: CGFloat

    public init(_ kind: PlaceholderKind, side: CGFloat) {
        self.kind = kind
        self.side = side
    }

    public var body: some View {
        Image(systemName: kind.symbol)
            .font(.system(size: min(max(side * 0.4, 12), 64)))
            .foregroundStyle(.white.opacity(0.6))
            .accessibilityHidden(true)
    }
}

/// The brand's rabbit-ears set: two antennae over a rounded screen, stroked by the caller.
public struct StationMark: Shape {
    public init() {}

    public func path(in rect: CGRect) -> Path {
        var path = Path()
        let screen = CGRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height / 2)
        path.addRoundedRect(in: screen, cornerSize: CGSize(width: rect.height / 8, height: rect.height / 8))
        path.move(to: CGPoint(x: rect.minX + rect.width * 0.2, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX - rect.width * 0.2, y: rect.minY))
        return path
    }
}
