import RabbitEarsKit
import SwiftUI

/// The board's seek bar. While the pointer is over it or dragging, a card
/// shows the stream's preview frame for that position; no previews, no card.
struct ScrubBar: View {
    let position: Double
    let duration: Double
    let previewURL: (Double) -> URL?
    let onScrub: (Double) -> Void
    let onCommit: (Double) -> Void
    @State private var pointerX: Double?
    @State private var dragging = false

    private let card = 260.0

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let fraction = duration > 0 ? min(1, max(0, position / duration)) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.25)).frame(height: 4)
                Capsule().fill(Theme.amber).frame(width: width * fraction, height: 4)
                Circle().fill(Theme.amber).frame(width: 14, height: 14).offset(x: width * fraction - 7)
            }
            .frame(maxHeight: .infinity)
            .overlay(alignment: .bottomLeading) {
                if let pointer = pointerX, duration > 0 {
                    let seconds = Scrub.seconds(atX: pointer, width: width, duration: duration)
                    if let url = previewURL(seconds) {
                        previewCard(url: url, seconds: seconds)
                            .offset(x: Scrub.cardCenter(atX: pointer, width: width, card: card) - card / 2, y: -30)
                            .allowsHitTesting(false)
                    }
                }
            }
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        guard duration > 0 else { return }
                        dragging = true
                        pointerX = drag.location.x
                        onScrub(Scrub.seconds(atX: drag.location.x, width: width, duration: duration))
                    }
                    .onEnded { drag in
                        dragging = false
                        pointerX = nil
                        guard duration > 0 else { return }
                        onCommit(Scrub.seconds(atX: drag.location.x, width: width, duration: duration))
                    }
            )
            .onContinuousHover { phase in
                switch phase {
                case .active(let point): if !dragging { pointerX = point.x }
                case .ended: if !dragging { pointerX = nil }
                }
            }
        }
        .frame(height: 24)
        .accessibilityElement()
        .accessibilityLabel("Seek")
        .accessibilityValue(Format.clock(seconds: position))
        .accessibilityAdjustableAction { direction in
            onCommit(max(0, position + (direction == .increment ? 10 : -10)))
        }
    }

    private func previewCard(url: URL, seconds: Double) -> some View {
        VStack(spacing: 0) {
            AsyncImage(url: url) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                LinearGradient(
                    colors: [Color(hex: 0x2E6B8A), Color(hex: 0x17304A), Color(hex: 0x0E1C2C)], startPoint: .topLeading,
                    endPoint: .bottomTrailing)
            }
            .frame(width: card, height: card * 9 / 16).clipped()
            HStack {
                Text(Format.clock(seconds: seconds))
                Spacer()
            }
            .font(.system(size: 12, weight: .semibold)).monospacedDigit().padding(.horizontal, 10).padding(.vertical, 6)
        }
        .frame(width: card)
        .background(Theme.ground)
        .clipShape(.rect(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.18)))
        .shadow(color: .black.opacity(0.6), radius: 15, y: 10)
    }
}
