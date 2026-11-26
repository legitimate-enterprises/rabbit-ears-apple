import RabbitEarsKit
import SwiftUI

/// The board's seek bar. While a finger drags it, a card above shows the
/// stream's preview frame for that position; no previews, no card.
struct ScrubBar: View {
    let position: Double
    let duration: Double
    let previewURL: (Double) -> URL?
    let onScrub: (Double) -> Void
    let onCommit: (Double) -> Void
    @State private var fingerX: Double?

    private let card = 200.0

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
                if let finger = fingerX, duration > 0 {
                    let seconds = Scrub.seconds(atX: finger, width: width, duration: duration)
                    if let url = previewURL(seconds) {
                        previewCard(url: url, seconds: seconds)
                            .offset(x: Scrub.cardCenter(atX: finger, width: width, card: card) - card / 2, y: -42)
                            .allowsHitTesting(false)
                    }
                }
            }
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        fingerX = drag.location.x
                        onScrub(Scrub.seconds(atX: drag.location.x, width: width, duration: duration))
                    }
                    .onEnded { drag in
                        fingerX = nil
                        onCommit(Scrub.seconds(atX: drag.location.x, width: width, duration: duration))
                    }
            )
        }
        .frame(height: 44)
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
