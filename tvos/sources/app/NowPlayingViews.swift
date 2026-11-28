import RabbitEarsAPI
import RabbitEarsKit
import SwiftUI

/// Up next only shows what is coming, since the queue is not edited on a TV.
/// Focus runs art, surface, controls from top to bottom; the art takes focus
/// only while the stream carries file details.
struct NowPlayingView: View {
    enum Focus: Hashable { case art, surface, shuffle, `repeat` }

    @Environment(MusicPlayer.self) private var player
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focus: Focus?
    @State private var details = false

    var body: some View {
        Group {
            if let tuner = player.station {
                StationNowPlaying(tuner: tuner)
            } else {
                queue
            }
        }
        // Stop, or the queue running out, leaves nothing to show.
        .onChange(of: player.current == nil && player.station == nil) { _, gone in if gone { dismiss() } }
    }

    private var queue: some View {
        ZStack {
            NowPlayingGround()
            Button {
                Task { await player.toggle() }
            } label: {
                Color.clear
            }
            .buttonStyle(BareButtonStyle())
            .focused($focus, equals: .surface)
            .onMoveCommand(perform: move)
            if let song = player.current, player.stream != nil {
                HStack(alignment: .top, spacing: 96) {
                    nowPlaying(song).frame(width: 760, alignment: .leading)
                    upNext.frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .padding(Theme.safeArea)
            } else {
                Text("Nothing is playing").font(.system(size: 40, weight: .semibold)).foregroundStyle(Theme.secondary)
            }
        }
        .foregroundStyle(Theme.light)
        .ignoresSafeArea()
        .defaultFocus($focus, .surface)
        .onChange(of: player.stream?.audio == nil) { _, gone in if gone && focus == .art { focus = .surface } }
        .onPlayPauseCommand { Task { await player.toggle() } }
        .toolbar(.hidden, for: .navigationBar)
    }

    private func nowPlaying(_ song: MusicSong) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            art(song).frame(width: 500, height: 500).shadow(color: .black.opacity(0.5), radius: 40, y: 20)
            TrackLines(title: song.title, artist: song.artistName, album: song.albumTitle).padding(.top, 32)
            TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                let duration = Double(song.durationMs ?? 0) / 1000
                let position = min(Double(player.positionMs) / 1000, duration)
                VStack(spacing: 8) {
                    ScrubTrack(position: position, duration: duration, scrubbing: false, preview: nil)
                    HStack {
                        Text(Format.clock(seconds: position))
                        Spacer()
                        Text("-" + Format.clock(seconds: duration - position))
                    }
                    .font(.system(size: 30)).monospacedDigit()
                }
            }
            .padding(.top, 28)
            HStack(spacing: 20) {
                Button {
                    player.setShuffle(!player.queue.shuffled)
                } label: {
                    Label("Shuffle", systemImage: "shuffle")
                }
                .buttonStyle(ToggleStyle(on: player.queue.shuffled))
                .focused($focus, equals: .shuffle)
                Button {
                    player.setRepeat(player.queue.repeatMode.cycled)
                } label: {
                    Label(
                        player.queue.repeatMode.label,
                        systemImage: player.queue.repeatMode == .one ? "repeat.1" : "repeat")
                }
                .buttonStyle(ToggleStyle(on: player.queue.repeatMode != .off))
                .focused($focus, equals: .repeat)
                let starred = app.favorites.contains(song.id)
                Button {
                    Task { await app.setFavorite(!starred, song.id) }
                } label: {
                    Label("Favorite", systemImage: starred ? "star.fill" : "star")
                }
                .buttonStyle(ToggleStyle(on: starred))
                .accessibilityAddTraits(starred ? .isSelected : [])
                Button {
                    Task { await player.stop() }
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .buttonStyle(ToggleStyle(on: false))
                Text("Click left or right to change track").font(.system(size: 28)).foregroundStyle(Theme.secondary)
                    .padding(.leading, 8)
            }
            .focusSection()
            .onMoveCommand { if $0 == .up { focus = .surface } }
            .padding(.top, 24)
        }
    }

    private var upNext: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Up next").font(.system(size: 52, weight: .bold))
            Text("Playing from \(player.queue.source)").font(.system(size: 30)).foregroundStyle(Theme.secondary)
                .padding(.top, 4)
            VStack(spacing: 0) {
                ForEach(Array(player.queue.upNext.prefix(8).enumerated()), id: \.element.id) { index, entry in
                    HStack(spacing: 24) {
                        Text("\(index + 1)").foregroundStyle(Theme.secondary).frame(width: 56, alignment: .trailing)
                        Text(entry.song.title).font(.system(size: 32, weight: .semibold)).lineLimit(1)
                        Spacer(minLength: 20)
                        Text(entry.song.durationMs.map { Format.clock(seconds: Double($0) / 1000) } ?? "")
                            .foregroundStyle(Theme.secondary).monospacedDigit()
                    }
                    .font(.system(size: 30))
                    .padding(.vertical, 18)
                }
            }
            .padding(.top, 28)
            if player.queue.upNext.isEmpty {
                Text("Nothing after this").font(.system(size: 30)).foregroundStyle(Theme.secondary).padding(.top, 28)
            }
        }
    }

    /// Select turns the art over to the file details and back.
    @ViewBuilder
    private func art(_ song: MusicSong) -> some View {
        let cover = ArtBlock(id: song.albumId, radius: 20, placeholder: .album)
        if let audio = player.stream?.audio {
            let groups = Format.audioDetails(audio)
            // Under Reduce Motion the faces only crossfade.
            let turn = reduceMotion ? 0.0 : 180
            Button {
                withAnimation(.easeInOut(duration: reduceMotion ? 0.2 : 0.45)) { details.toggle() }
            } label: {
                ZStack {
                    cover.modifier(CardFace(degrees: details ? turn : 0)).opacity(reduceMotion && details ? 0 : 1)
                    FileDetails(groups: groups)
                        .modifier(CardFace(degrees: details ? 0 : -turn)).opacity(reduceMotion && !details ? 0 : 1)
                }
            }
            .buttonStyle(CardButtonStyle(scale: 1.05))
            .focused($focus, equals: .art)
            .onMoveCommand { if $0 == .down { focus = .surface } }
            .accessibilityLabel(details ? "File details" : "Album art")
            .accessibilityValue(
                details ? groups.flatMap(\.rows).map { "\($0.label) \($0.value)" }.joined(separator: ", ") : ""
            )
            .accessibilityHint(details ? "Shows the album art" : "Shows file details")
            .accessibilityAddTraits(details ? .isSelected : [])
        } else {
            cover
        }
    }

    private func move(_ direction: MoveCommandDirection) {
        switch direction {
        case .left: Task { await player.previous() }
        case .right: Task { await player.next() }
        case .up: if player.stream?.audio != nil { focus = .art }
        case .down: focus = .shuffle
        default: break
        }
    }
}

/// Fixed slots, two lines of title then the artist and the album, so what sits
/// below holds still from one song to the next.
struct TrackLines: View {
    let title: String
    let artist: String
    let album: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 60, weight: .bold)).lineLimit(2, reservesSpace: true)
                .minimumScaleFactor(0.6)
            Group {
                Text(artist).font(.system(size: 32, weight: .semibold))
                Text(album).font(.system(size: 30))
            }
            .foregroundStyle(Theme.synopsis).lineLimit(1, reservesSpace: true)
        }
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

/// The file details in the art's 500-point square, in this screen's type scale.
private struct FileDetails: View {
    let groups: [AudioDetailGroup]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(groups) { group in
                VStack(alignment: .leading, spacing: 0) {
                    Text(group.title).font(.system(size: 26, weight: .bold)).frame(height: 34)
                    ForEach(group.rows) { row in
                        HStack(spacing: 10) {
                            Text(row.label).foregroundStyle(Theme.secondary)
                            Spacer(minLength: 10)
                            if let tag = row.tag { Tag(text: tag) }
                            Text(row.value).monospacedDigit()
                                .fontWeight(row.tone == .plain ? .medium : .semibold)
                                .foregroundStyle(Self.color(row.tone))
                        }
                        .font(.system(size: 26)).lineLimit(1).frame(height: 38)
                    }
                }
            }
        }
        .padding(.horizontal, 32).padding(.vertical, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.card, in: .rect(cornerRadius: 20))
    }

    private static func color(_ tone: AudioDetailRow.Tone) -> Color {
        switch tone {
        case .plain: Theme.light
        case .success: Theme.green
        case .caution: Theme.amber
        }
    }
}

struct NowPlayingGround: View {
    var body: some View {
        LinearGradient(colors: [Color(hex: 0x2D2326), Theme.ground], startPoint: .topLeading, endPoint: .bottom)
    }
}

private struct ToggleStyle: ButtonStyle {
    let on: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 28, weight: .bold))
            .labelStyle(TVLabelStyle())
            .padding(.horizontal, 24)
            .frame(height: 64)
            .background(Theme.control, in: .capsule)
            .modifier(OnText(on: on))
            .modifier(FocusLift(scale: 1.05))
    }

    private struct OnText: ViewModifier {
        @Environment(\.isFocused) private var focused
        let on: Bool
        func body(content: Content) -> some View {
            if on && !focused { content.foregroundStyle(Theme.amber) } else { content }
        }
    }
}
