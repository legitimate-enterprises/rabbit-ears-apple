import AVKit
import RabbitEarsAPI
import RabbitEarsKit
import SwiftUI

struct MiniPlayer: View {
    let player: RabbitEarsKit.MusicPlayer
    let open: () -> Void

    var body: some View {
        if let tuner = player.station {
            StationMiniPlayer(player: player, tuner: tuner, open: open)
        } else if let song = player.current {
            HStack(spacing: 10) {
                Button(action: open) {
                    HStack(spacing: 10) {
                        ArtSquare(id: song.albumId, radius: 6, placeholder: .album, badges: StatusBadges(id: song.id))
                            .frame(width: 40)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(song.title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                            Text(song.artistName).font(.system(size: 12)).foregroundStyle(Theme.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Now playing: \(song.title), \(song.artistName)")
                Button {
                    Task { await player.toggle() }
                } label: {
                    Image(systemName: player.playing ? "pause.fill" : "play.fill").font(.system(size: 20))
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel(player.playing ? "Pause" : "Play")
                Button {
                    Task { await player.next() }
                } label: {
                    Image(systemName: "forward.end.fill").font(.system(size: 18)).frame(width: 44, height: 44)
                }
                .accessibilityLabel("Next")
                Button {
                    Task { await player.stop() }
                } label: {
                    Image(systemName: "stop.fill").font(.system(size: 18)).frame(width: 44, height: 44)
                }
                .accessibilityLabel("Stop")
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 10)
            .overlay(alignment: .bottom) {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    ProgressBar(value: fraction(song)).padding(.horizontal, 10)
                }
            }
        }
    }

    private func fraction(_ song: MusicSong) -> Double {
        guard let duration = song.durationMs, duration > 0 else { return 0 }
        return min(1, max(0, Double(player.positionMs) / Double(duration)))
    }
}

struct NowPlayingView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(AppModel.self) private var app
    @Environment(Browser.self) private var browser
    let player: RabbitEarsKit.MusicPlayer
    @State private var showingQueue = false
    @State private var scrubbing: Double?
    @State private var target: PlaylistTarget?
    /// Kept across songs while the player is open; the panel waits for each song's stream.
    @State private var showingDetails = false
    /// How far the player follows a finger pulling it down to close.
    @State private var pull: CGFloat = 0

    var body: some View {
        ZStack {
            Theme.ground.ignoresSafeArea()
            if let tuner = player.station {
                StationNowPlaying(player: player, tuner: tuner)
            } else if let song = player.current {
                LinearGradient(
                    colors: [ArtPalette.color(song.albumId).opacity(0.55), Theme.ground], startPoint: .top,
                    endPoint: .center
                )
                .ignoresSafeArea()
                VStack(spacing: 18) {
                    header(song)
                    cover(song)
                    SongTitles(song: song, go: go)
                    scrubber(song)
                    transport
                    Spacer(minLength: 0)
                    bottom(song)
                }
                .padding(.horizontal, 32)
                .padding(.vertical, 12)
            }
        }
        .foregroundStyle(Theme.primary)
        .offset(y: pull)
        // Global, so the translation holds still while the player moves under the finger.
        .gesture(DragGesture(minimumDistance: 12, coordinateSpace: .global).onChanged(pulled).onEnded(released))
        // What the player is pulled down from shows behind it, not an empty cover.
        .presentationBackground(.clear)
        .addToPlaylist($target)
        .sheet(isPresented: $showingQueue) {
            QueueSheet(player: player).presentationDetents([.fraction(0.72), .large])
                .presentationBackground(Theme.raised)
        }
        .alert(
            player.alert ?? "",
            isPresented: Binding(get: { player.alert != nil }, set: { if !$0 { player.alert = nil } })
        ) {
            Button("OK") {}
        }
        .onChange(of: player.current == nil && player.station == nil) { _, gone in if gone { dismiss() } }
    }

    private func header(_ song: MusicSong) -> some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.down").font(.system(size: 18, weight: .semibold)).frame(
                    width: 44, height: 44)
            }
            .accessibilityLabel("Close")
            Spacer()
            VStack(spacing: 1) {
                Text("Playing from").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                Text(player.queue.source).font(.system(size: 14, weight: .semibold)).lineLimit(1)
            }
            Spacer()
            // Its only items add to a playlist or station, which kids cannot.
            if app.activeProfile?.kind == .adult {
                Menu {
                    AddToButtons(target: $target, itemIds: [song.id], kind: .music)
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 18)).frame(width: 44, height: 44)
                }
                .accessibilityLabel("More")
            } else {
                Color.clear.frame(width: 44, height: 44)
            }
        }
    }

    private func go(_ route: Route) {
        dismiss()
        browser.open(route)
    }

    /// The art, which turns over to the file details once the song's stream says what they are.
    private func cover(_ song: MusicSong) -> some View {
        let details = player.stream?.audio.map(Format.audioDetails)
        let showing = showingDetails && details != nil
        return FlipCard(turn: showing ? 1 : 0, flat: reduceMotion) {
            ArtSquare(id: song.albumId, radius: 14, placeholder: .album, badges: StatusBadges(id: song.id))
        } back: {
            if let details { AudioDetailsPanel(groups: details) }
        }
        .shadow(color: .black.opacity(0.5), radius: 24, y: 12)
        .overlay(alignment: .bottom) {
            Capsule().fill(.white.opacity(0.3)).frame(width: 36, height: 4).offset(y: 11)
                .opacity(details == nil ? 0 : 1)
        }
        .contentShape(.rect)
        .onTapGesture { if details != nil { flip() } }
        .gesture(
            DragGesture(minimumDistance: 12, coordinateSpace: .global)
                // Pulling the panel down turns it back and never closes the player.
                .onChanged { if !showing { pulled($0) } }
                .onEnded { value in
                    let down = value.translation.height
                    if showing {
                        if down > 30 { flip() }
                    } else if down < -30, details != nil {
                        flip()
                    } else {
                        released(value)
                    }
                }
        )
        // One element, so it carries what the art's own badge would say.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            showing ? "File details" : details == nil ? "Album art" : "Album art. Swipe up or tap for file details"
        )
        .accessibilityValue(showing ? AudioDetailsPanel.spoken(details ?? []) : downloaded(song) ? "Downloaded" : "")
        .accessibilityAddTraits(details == nil ? [] : .isButton)
        .accessibilityAction { if details != nil { flip() } }
        .accessibilityHidden(details == nil && !downloaded(song))
    }

    /// When the art's `StatusBadges` shows its Downloaded mark.
    private func downloaded(_ song: MusicSong) -> Bool {
        guard let store = app.downloads, let profile = app.activeProfile?.id else { return false }
        return store.badged(song.id, profile: profile)
    }

    private func flip() {
        withAnimation(.easeInOut(duration: reduceMotion ? 0.25 : 0.45)) { showingDetails.toggle() }
    }

    private func pulled(_ value: DragGesture.Value) {
        pull = max(0, value.translation.height)
    }

    /// Closes when pulled well down or flicked down; otherwise springs back.
    private func released(_ value: DragGesture.Value) {
        if value.translation.height > 200 || value.predictedEndTranslation.height > 400 {
            dismiss()
        } else {
            withAnimation(.spring) { pull = 0 }
        }
    }

    private func scrubber(_ song: MusicSong) -> some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            let duration = Double(song.durationMs ?? 0) / 1000
            let position = scrubbing ?? Double(player.positionMs) / 1000
            VStack(spacing: 2) {
                Slider(
                    value: Binding(get: { min(position, max(duration, 1)) }, set: { scrubbing = $0 }),
                    in: 0...max(duration, 1)
                ) { editing in
                    if !editing, let target = scrubbing {
                        player.seek(toMs: Int64(target * 1000))
                        scrubbing = nil
                    }
                }
                .tint(Theme.amber)
                .accessibilityLabel("Position")
                HStack {
                    Text(Format.clock(seconds: position))
                    Spacer()
                    Text("-" + Format.clock(seconds: max(0, duration - position)))
                }
                .font(.system(size: 12)).monospacedDigit().foregroundStyle(Theme.secondary)
            }
        }
    }

    private var transport: some View {
        let queue = player.queue
        return HStack {
            Button {
                player.setShuffle(!queue.shuffled)
            } label: {
                Image(systemName: "shuffle").foregroundStyle(queue.shuffled ? Theme.amber : Theme.primary)
            }
            .accessibilityLabel("Shuffle")
            .accessibilityValue(queue.shuffled ? "On" : "Off")
            Spacer()
            Button {
                Task { await player.previous() }
            } label: {
                Image(systemName: "backward.end.fill").font(.system(size: 26))
            }
            .accessibilityLabel("Previous")
            Spacer()
            Button {
                Task { await player.toggle() }
            } label: {
                Image(systemName: player.playing ? "pause.fill" : "play.fill").font(.system(size: 32))
                    .foregroundStyle(Theme.ground).frame(width: 72, height: 72).background(Theme.amber, in: .circle)
            }
            .accessibilityLabel(player.playing ? "Pause" : "Play")
            Spacer()
            Button {
                Task { await player.next() }
            } label: {
                Image(systemName: "forward.end.fill").font(.system(size: 26))
            }
            .accessibilityLabel("Next")
            Spacer()
            Button {
                player.setRepeat(queue.repeatMode.cycled)
            } label: {
                Image(systemName: queue.repeatMode == .one ? "repeat.1" : "repeat")
                    .foregroundStyle(queue.repeatMode == .off ? Theme.primary : Theme.amber)
            }
            .accessibilityLabel("Repeat")
            .accessibilityValue(Self.name(queue.repeatMode))
        }
        .font(.system(size: 20))
        .buttonStyle(.plain)
    }

    static func name(_ mode: RepeatMode) -> String {
        switch mode {
        case .off: "Off"
        case .all: "All"
        case .one: "One"
        }
    }

    private func bottom(_ song: MusicSong) -> some View {
        HStack {
            AirPlayButton().frame(width: 44, height: 44).accessibilityLabel("AirPlay")
            FavoriteButton(id: song.id, side: 44).font(.system(size: 20)).buttonStyle(.plain)
            Spacer()
            Button {
                Task { await player.stop() }
            } label: {
                Image(systemName: "stop.fill").font(.system(size: 20)).frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Stop")
            Spacer()
            Button {
                showingQueue = true
            } label: {
                Label("Up next", systemImage: "list.bullet.indent").font(.system(size: 15, weight: .semibold))
                    .padding(.horizontal, 18).frame(height: 44).background(.white.opacity(0.12), in: .capsule)
            }
            .buttonStyle(.plain)
        }
    }
}

/// The AirPlay button for audio, where the player's one prefers video routes.
struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = .white
        view.activeTintColor = UIColor(Theme.amber)
        return view
    }

    func updateUIView(_ view: AVRoutePickerView, context: Context) {}
}

struct QueueSheet: View {
    let player: RabbitEarsKit.MusicPlayer

    var body: some View {
        let queue = player.queue
        let upNext = queue.upNext
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Up next").font(.system(size: 22, weight: .bold)).accessibilityAddTraits(.isHeader)
                Spacer()
                Button("Clear") { player.clearUpNext() }.buttonStyle(LinkButtonStyle()).disabled(upNext.isEmpty)
            }
            Text(summary(queue, upNext)).font(.system(size: 13)).foregroundStyle(Theme.secondary)
            if upNext.isEmpty {
                Text("Nothing is queued after this song.").foregroundStyle(Theme.secondary)
                    .frame(maxWidth: .infinity).padding(.top, 40)
                Spacer()
            } else {
                List {
                    ForEach(upNext) { entry in
                        row(entry.song)
                            .contentShape(.rect)
                            .onTapGesture { Task { await player.jump(to: entry.id) } }
                            .contextMenu {
                                Button("Remove from Up next", systemImage: "minus.circle", role: .destructive) {
                                    player.removeFromUpNext(entry.id)
                                }
                            }
                            .accessibilityAction(named: "Remove from Up next") { player.removeFromUpNext(entry.id) }
                            .deleteDisabled(true)
                            .listRowBackground(Color.clear).listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
                    }
                    .onMove { player.moveUpNext(fromOffsets: $0, toOffset: $1) }
                }
                .listStyle(.plain).scrollContentBackground(.hidden)
                .environment(\.editMode, .constant(.active))
            }
        }
        .padding(.horizontal, 20).padding(.top, 24)
        .foregroundStyle(Theme.primary)
    }

    private func summary(_ queue: AudioQueue, _ upNext: [AudioQueue.Entry]) -> String {
        let total = upNext.reduce(Int64(0)) { $0 + ($1.song.durationMs ?? 0) }
        return "Playing from \(queue.source) · \(Format.songs(upNext.count, durationMs: total))"
    }

    private func row(_ song: MusicSong) -> some View {
        HStack(spacing: 12) {
            ArtSquare(id: song.albumId, radius: 6, placeholder: .album, badges: StatusBadges(id: song.id))
                .frame(width: 44)
            VStack(alignment: .leading, spacing: 1) {
                Text(song.title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                Text(
                    [song.artistName, song.durationMs.map { Format.clock(seconds: Double($0) / 1000) }]
                        .compactMap { $0 }.joined(separator: " · ")
                )
                .font(.system(size: 12)).foregroundStyle(Theme.secondary).lineLimit(1)
            }
        }
    }
}
