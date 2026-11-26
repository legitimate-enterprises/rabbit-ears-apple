import SwiftUI

/// A play arrow in a translucent circle, centered over a tile's art to say the tile plays when
/// activated. The dark disc keeps it legible over any art.
public struct PlayBadge: View {
    let size: CGFloat

    public init(size: CGFloat = 34) { self.size = size }

    public var body: some View {
        Image(systemName: "play.fill")
            .font(.system(size: size * 0.4))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(.black.opacity(0.55), in: .circle)
            .accessibilityHidden(true)
    }
}

extension View {
    /// Says `label` to a screen reader when there is one, else leaves what the view says as it is.
    @ViewBuilder
    public func labeled(_ label: String?) -> some View {
        if let label { accessibilityLabel(label) } else { self }
    }
}
