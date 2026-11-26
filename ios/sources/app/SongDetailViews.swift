import RabbitEarsAPI
import RabbitEarsKit
import SwiftUI

/// Title, artist and album in fixed slots, so the controls below stay put
/// whatever the title's length and while the next song loads. Sizes are
/// fixed points, so Dynamic Type cannot grow the slots; long lines truncate.
struct SongTitles: View {
    let song: MusicSong
    /// Opens the artist or album; without it the lines are not buttons.
    var go: ((Route) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(song.title).font(.system(size: 22, weight: .bold)).kerning(-0.3).lineLimit(2)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).frame(height: 52)
            line(song.artistName, font: .system(size: 17, weight: .semibold), height: 22, route: .artist(song.artistId))
            line(song.albumTitle, font: .system(size: 15, weight: .medium), height: 20, route: .album(song.albumId))
        }
        .frame(height: 94)
    }

    @ViewBuilder
    private func line(_ text: String, font: Font, height: CGFloat, route: Route) -> some View {
        let label = Text(text).font(font).foregroundStyle(Theme.amber).lineLimit(1).frame(height: height)
        if let go {
            Button {
                go(route)
            } label: {
                label
            }.buttonStyle(.plain)
        } else {
            label
        }
    }
}

/// Turns `front` over about its horizontal axis to show `back`, swapping
/// faces edge on so neither shows mirrored; `flat`, a crossfade instead.
struct FlipCard<Front: View, Back: View>: View, Animatable {
    /// 0 shows the front, 1 the back.
    var turn: Double
    let flat: Bool
    @ViewBuilder let front: Front
    @ViewBuilder let back: Back

    nonisolated var animatableData: Double {
        get { turn }
        set { turn = newValue }
    }

    var body: some View {
        let backShown = flat ? turn : (turn < 0.5 ? 0 : 1)
        front.opacity(1 - backShown)
            .overlay { back.rotation3DEffect(.degrees(flat ? 0 : 180), axis: (x: 1, y: 0, z: 0)).opacity(backShown) }
            .rotation3DEffect(.degrees(flat ? 0 : turn * 180), axis: (x: 1, y: 0, z: 0), perspective: 0.4)
    }
}

/// A song's file details in the art's footprint, every row showing at any art size.
struct AudioDetailsPanel: View {
    let groups: [AudioDetailGroup]

    var body: some View {
        GeometryReader { space in
            let metrics = AudioDetailMetrics.fitting(groups, in: space.size.height)
            // Laid out larger by the inverse of the scale, so scaled down it fills the art.
            content(metrics)
                .frame(width: space.size.width / metrics.scale, height: space.size.height / metrics.scale)
                .scaleEffect(metrics.scale)
                .frame(width: space.size.width, height: space.size.height)
        }
        .background(Theme.raised, in: .rect(cornerRadius: 14))
    }

    private func content(_ metrics: AudioDetailMetrics) -> some View {
        VStack(alignment: .leading, spacing: metrics.gap) {
            ForEach(groups) { group in
                VStack(alignment: .leading, spacing: 0) {
                    Text(group.title).font(.system(size: 13, weight: .bold))
                        .frame(height: metrics.heading, alignment: .top)
                    ForEach(group.rows) { row in
                        HStack(spacing: 6) {
                            Text(row.label).foregroundStyle(Theme.secondary)
                            Spacer(minLength: 0)
                            if let tag = row.tag { Tag(text: tag) }
                            Text(row.value).fontWeight(row.tone == .plain ? .medium : .semibold)
                                .foregroundStyle(Self.color(row.tone)).layoutPriority(1)
                        }
                        .font(.system(size: 14)).monospacedDigit().lineLimit(1).frame(height: metrics.row)
                    }
                }
            }
        }
        .padding(.horizontal, metrics.inset).padding(.vertical, metrics.padding)
    }

    static func color(_ tone: AudioDetailRow.Tone) -> Color {
        switch tone {
        case .plain: Theme.primary
        case .success: Theme.green
        case .caution: Theme.amber
        }
    }

    /// The rows as VoiceOver reads them: `Source. Format, Lossless FLAC. Bitrate, 2,116 kb/s.`
    static func spoken(_ groups: [AudioDetailGroup]) -> String {
        groups.map { group in
            ([group.title]
                + group.rows.map { "\($0.label), \([$0.tag, $0.value].compactMap { $0 }.joined(separator: " "))" })
                .joined(separator: ". ")
        }
        .joined(separator: ". ")
    }
}
