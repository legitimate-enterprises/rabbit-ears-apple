import RabbitEarsAPI
import RabbitEarsKit
import SwiftUI

/// The album art, turning over to the stream's file details on a click;
/// without `audio` there are no details to turn to.
struct ArtOrDetails: View {
    let song: MusicSong
    let audio: Components.Schemas.AudioDetails?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var details = false

    var body: some View {
        let groups = audio.map(Format.audioDetails)
        let flipped = details && groups != nil
        // Under Reduce Motion the faces only crossfade.
        let turn = reduceMotion ? 0.0 : 180
        ZStack {
            // A downloaded copy plays without `audio`, so its badge never sits under the info button.
            Art(
                id: song.albumId, radius: 12, placeholder: .album, badges: StatusBadges(id: song.id),
                badged: groups == nil
            )
            .modifier(CardFace(degrees: flipped ? turn : 0)).opacity(reduceMotion && flipped ? 0 : 1)
            if let groups {
                FileDetails(groups: groups)
                    .modifier(CardFace(degrees: flipped ? 0 : -turn)).opacity(reduceMotion && !flipped ? 0 : 1)
                    .accessibilityHidden(!flipped)
            }
        }
        .frame(width: 300, height: 300)
        .contentShape(.rect)
        .onTapGesture { if groups != nil { toggle() } }
        .overlay(alignment: .bottomTrailing) {
            if groups != nil {
                Button(action: toggle) {
                    Image(systemName: "info.circle").font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(flipped ? Theme.amber : Theme.primary)
                        .frame(width: 28, height: 28).background(.black.opacity(0.6), in: .circle)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(flipped ? "Show album art" : "Show file details")
                .accessibilityAddTraits(flipped ? .isSelected : [])
                .padding(10)
            }
        }
        .shadow(color: .black.opacity(0.4), radius: 20, y: 8)
    }

    private func toggle() {
        withAnimation(.easeInOut(duration: reduceMotion ? 0.2 : 0.45)) { details.toggle() }
    }
}

/// One face of a card turning about its vertical axis, unseen once past edge-on.
nonisolated private struct CardFace: ViewModifier, Animatable {
    var degrees: Double
    var animatableData: Double {
        get { degrees }
        set { degrees = newValue }
    }

    func body(content: Content) -> some View {
        content.rotation3DEffect(.degrees(degrees), axis: (x: 0, y: 1, z: 0)).opacity(abs(degrees) < 90 ? 1 : 0)
    }
}

private struct FileDetails: View {
    let groups: [AudioDetailGroup]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(groups) { group in
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.title).font(.system(size: 12, weight: .bold)).accessibilityAddTraits(.isHeader)
                    ForEach(group.rows) { row in
                        HStack(spacing: 6) {
                            Text(row.label).foregroundStyle(Theme.secondary)
                            Spacer(minLength: 6)
                            if let tag = row.tag { Tag(text: tag) }
                            Text(row.value).monospacedDigit()
                                .fontWeight(row.tone == .plain ? .medium : .semibold)
                                .foregroundStyle(Self.color(row.tone))
                        }
                        .font(.system(size: 13)).lineLimit(1).frame(height: 22)
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.raised, in: .rect(cornerRadius: 12))
        .accessibilityElement(children: .contain).accessibilityLabel("File details")
    }

    private static func color(_ tone: AudioDetailRow.Tone) -> Color {
        switch tone {
        case .plain: Theme.primary
        case .success: Theme.green
        case .caution: Theme.amber
        }
    }
}
