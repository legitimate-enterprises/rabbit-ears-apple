import RabbitEarsAPI
import RabbitEarsKit
import SwiftUI

struct MiniPlayer: View {
    @Environment(MusicPlayer.self) private var player
    @Environment(Browser.self) private var browser
    let audio: AVAudioOutput
    @State private var scrubbing: Double?

    var body: some View {
        if let tuner = player.station {
            StationMiniPlayer(tuner: tuner, audio: audio)
        } else if let song = player.current {
            HStack(spacing: 16) {
                Button {
                    browser.open(.nowPlaying)
                } label: {
                    HStack(spacing: 12) {
                        Art(id: song.albumId, radius: 4, placeholder: .album, badges: StatusBadges(id: song.id))
                            .frame(width: 40, height: 40)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(song.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                            Text("\(song.artistName) · \(song.albumTitle)").font(.system(size: 12))
                                .foregroundStyle(Theme.secondary).lineLimit(1)
                        }
                        .frame(width: 210, alignment: .leading)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Now playing: \(song.title), \(song.artistName)")
                Transport()
                TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                    let duration = Double(song.durationMs ?? 0) / 1000
                    let position = scrubbing ?? Double(player.positionMs) / 1000
                    HStack(spacing: 10) {
                        Text(Format.clock(seconds: position)).monospacedDigit()
                        ScrubBar(
                            position: position, duration: duration, previewURL: { _ in nil },
                            onScrub: { scrubbing = $0 },
                            onCommit: {
                                player.seek(toMs: Int64($0 * 1000))
                                scrubbing = nil
                            }
                        )
                        .frame(height: 16)
                        Text(Format.clock(seconds: duration)).monospacedDigit()
                    }
                    .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                }
                VolumeSlider(player: audio.player)
            }
            .padding(.horizontal, 20).frame(height: 60)
            .background(Theme.raised)
            .overlay(alignment: .top) { Divider().overlay(Theme.hairline) }
        }
    }
}

/// The bar while a music station is tuned in; no knob, since nothing seeks a station.
struct StationMiniPlayer: View {
    @Environment(MusicPlayer.self) private var player
    @Environment(Browser.self) private var browser
    let tuner: StationTuner
    let audio: AVAudioOutput

    var body: some View {
        let station = tuner.station
        let song = player.current
        HStack(spacing: 16) {
            Button {
                browser.open(.nowPlaying)
            } label: {
                HStack(spacing: 12) {
                    Group {
                        if let song {
                            Art(id: song.albumId, radius: 4, placeholder: .album, badges: StatusBadges(id: song.id))
                        } else {
                            StationArt(station: station, radius: 4)
                        }
                    }
                    .frame(width: 40, height: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(song?.title ?? station.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        Text(
                            song.map { "\($0.artistName) · \(station.name)" }
                                ?? StationText.waiting(station.onAir, kind: .music)
                        )
                        .font(.system(size: 12)).foregroundStyle(Theme.secondary).lineLimit(1)
                    }
                    .frame(width: 210, alignment: .leading)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            Button {
                Task { await player.stop() }
            } label: {
                Image(systemName: "stop.fill").font(.system(size: 16)).frame(width: 30, height: 30).contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Stop")
            TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                let duration = Double(song?.durationMs ?? 0) / 1000
                let position = Double(player.positionMs) / 1000
                HStack(spacing: 10) {
                    Text(Format.clock(seconds: position)).monospacedDigit()
                    ProgressBar(value: duration > 0 ? min(1, position / duration) : 0)
                    Text(Format.clock(seconds: duration)).monospacedDigit()
                }
                .font(.system(size: 12)).foregroundStyle(Theme.secondary)
            }
            VolumeSlider(player: audio.player)
        }
        .padding(.horizontal, 20).frame(height: 60)
        .background(Theme.raised)
        .overlay(alignment: .top) { Divider().overlay(Theme.hairline) }
    }
}

struct Transport: View {
    @Environment(MusicPlayer.self) private var player

    var body: some View {
        HStack(spacing: 12) {
            button("backward.end.fill", "Previous", size: 16) { await player.previous() }
            button(player.playing ? "pause.fill" : "play.fill", player.playing ? "Pause" : "Play", size: 22) {
                await player.toggle()
            }
            button("forward.end.fill", "Next", size: 16) { await player.next() }
            button("stop.fill", "Stop", size: 14) { await player.stop() }
        }
        .alert(
            player.alert ?? "",
            isPresented: Binding(get: { player.alert != nil }, set: { if !$0 { player.alert = nil } })
        ) {
            Button("OK") { player.alert = nil }
        }
    }

    private func button(
        _ icon: String, _ label: String, size: CGFloat, action: @escaping () async -> Void
    ) -> some View {
        Button {
            Task { await action() }
        } label: {
            Image(systemName: icon).font(.system(size: size)).frame(width: 30, height: 30).contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

struct NowPlayingScreen: View {
    @Environment(MusicPlayer.self) private var player
    @Environment(Browser.self) private var browser

    var body: some View {
        if let tuner = player.station {
            HStack(alignment: .top, spacing: 36) {
                tuned(tuner.station)
                stationNext(tuner.station)
            }
            .padding(EdgeInsets(top: 18, leading: 22, bottom: 24, trailing: 22))
            .pageTitle("Now playing")
        } else if let song = player.current {
            HStack(alignment: .top, spacing: 36) {
                playing(song)
                upNext
            }
            .padding(EdgeInsets(top: 18, leading: 22, bottom: 24, trailing: 22))
            .pageTitle("Now playing")
        } else {
            ContentUnavailableView("Nothing playing", systemImage: "music.note")
        }
    }

    private func playing(_ song: MusicSong) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            ArtOrDetails(song: song, audio: player.stream?.audio)
            identity(song)
            HStack(spacing: 10) {
                Button {
                    player.setShuffle(!player.queue.shuffled)
                } label: {
                    Label("Shuffle", systemImage: "shuffle")
                        .foregroundStyle(player.queue.shuffled ? Theme.amber : .white)
                }
                .buttonStyle(SecondaryButtonStyle())
                Button {
                    player.setRepeat(Self.nextRepeat(player.queue.repeatMode))
                } label: {
                    Label("Repeat", systemImage: player.queue.repeatMode == .one ? "repeat.1" : "repeat")
                        .foregroundStyle(player.queue.repeatMode == .off ? .white : Theme.amber)
                }
                .buttonStyle(SecondaryButtonStyle())
            }
            Spacer(minLength: 0)
        }
        .frame(width: 300)
    }

    /// Fixed height, so the controls under it hold still from one song to the next.
    private func identity(_ song: MusicSong) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(song.title).font(.system(size: 20, weight: .bold)).lineLimit(2, reservesSpace: true)
            Group {
                Button(song.artistName) { browser.open(.artist(song.albumArtistId)) }.fontWeight(.semibold)
                Button(song.albumTitle) { browser.open(.album(song.albumId)) }.fontWeight(.medium)
            }
            .buttonStyle(.plain).font(.system(size: 13)).foregroundStyle(Theme.amber).lineLimit(1)
        }
        .frame(width: 300, height: 82, alignment: .topLeading)
    }

    private var upNext: some View {
        let entries = player.queue.upNext
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("Up next").font(.system(size: 18, weight: .bold))
                Text(
                    "Playing from \(player.queue.source) · "
                        + Format.songs(entries.count, durationMs: entries.reduce(0) { $0 + ($1.song.durationMs ?? 0) })
                )
                .font(.system(size: 13)).foregroundStyle(Theme.secondary).lineLimit(1)
                Spacer()
                if !entries.isEmpty { Button("Clear") { player.clearUpNext() }.buttonStyle(LinkButtonStyle()) }
            }
            if entries.isEmpty {
                Text("Nothing is queued after this song.").foregroundStyle(Theme.secondary).padding(.top, 8)
            } else {
                List {
                    ForEach(entries) { entry in row(entry) }
                        .onMove { player.moveUpNext(fromOffsets: $0, toOffset: $1) }
                }
                .listStyle(.plain).scrollContentBackground(.hidden)
                if let last = entries.last, player.queue.repeatMode == .off {
                    Text("Drag a song to reorder. The queue ends after \(last.song.title).")
                        .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func row(_ entry: AudioQueue.Entry) -> some View {
        HStack(spacing: 12) {
            Button {
                Task { await player.jump(to: entry.id) }
            } label: {
                HStack(spacing: 12) {
                    Art(id: entry.song.albumId, radius: 4, placeholder: .album, badges: StatusBadges(id: entry.song.id))
                        .frame(width: 36, height: 36)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry.song.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        Text(entry.song.artistName).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                    }
                    Spacer()
                    Text(Format.clock(seconds: Double(entry.song.durationMs ?? 0) / 1000)).monospacedDigit()
                        .font(.system(size: 13)).foregroundStyle(Theme.secondary)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            Button {
                player.removeFromUpNext(entry.id)
            } label: {
                Image(systemName: "xmark").foregroundStyle(Theme.secondary)
            }
            .buttonStyle(.plain).accessibilityLabel("Remove \(entry.song.title)")
        }
        .listRowBackground(Color.clear).listRowSeparator(.hidden)
    }

    private func tuned(_ station: Station) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if let song = player.current {
                ArtOrDetails(song: song, audio: player.stream?.audio)
                identity(song)
            } else {
                StationIdentity(name: station.name, aspect: 1, radius: 10, imageUrl: station.imageUrl).frame(width: 300)
                Text(station.name).font(.system(size: 20, weight: .bold))
                Text(StationText.waiting(station.onAir, kind: .music)).font(.system(size: 13))
                    .foregroundStyle(Theme.secondary)
            }
            HStack(spacing: 10) {
                Button {
                    Task { await player.leaveStation() }
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .buttonStyle(SecondaryButtonStyle())
                Text("Play joins \(station.name) where it is.").font(.system(size: 12))
                    .foregroundStyle(Theme.secondary)
            }
            Spacer(minLength: 0)
        }
        .frame(width: 300)
    }

    /// The station's Up next, read only: the server sets the order.
    private func stationNext(_ station: Station) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("Up next").font(.system(size: 18, weight: .bold))
                Text("On \(station.name)").font(.system(size: 13)).foregroundStyle(Theme.secondary).lineLimit(1)
            }
            ScrollView {
                VStack(spacing: 8) {
                    // A song can come round twice in one Up next, so rows are keyed by place.
                    ForEach(Array(StationText.upNext(station.onAir).enumerated()), id: \.offset) { _, song in
                        HStack(spacing: 12) {
                            Art(id: song.albumId, radius: 4, placeholder: .album, badges: StatusBadges(id: song.id))
                                .frame(width: 36, height: 36)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(song.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                                Text(song.artistName).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                            }
                            Spacer()
                            Text(Format.clock(seconds: Double(song.durationMs ?? 0) / 1000)).monospacedDigit()
                                .font(.system(size: 13)).foregroundStyle(Theme.secondary)
                        }
                        .padding(.horizontal, 10)
                    }
                }
            }
            Text("The station sets the order. Songs cannot be skipped, reordered or removed.")
                .font(.system(size: 12)).foregroundStyle(Theme.secondary)
        }
    }

    private static func nextRepeat(_ mode: RepeatMode) -> RepeatMode {
        switch mode {
        case .off: .all
        case .all: .one
        case .one: .off
        }
    }
}
