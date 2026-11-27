import RabbitEarsAPI
import RabbitEarsKit
import SwiftUI

/// The bar while a music station is tuned in: the song, or the station
/// off schedule, and Stop alone, since a station does not pause or skip.
struct StationMiniPlayer: View {
    let player: RabbitEarsKit.MusicPlayer
    let tuner: StationTuner
    let open: () -> Void

    var body: some View {
        let station = tuner.station
        let song = player.current
        HStack(spacing: 10) {
            Button(action: open) {
                HStack(spacing: 10) {
                    Group {
                        if let song {
                            ArtSquare(
                                id: song.albumId, radius: 6, placeholder: .album, badges: StatusBadges(id: song.id))
                        } else {
                            StationIdentity(
                                id: station.id, name: station.name, aspect: 1, radius: 6, imageUrl: station.imageUrl)
                        }
                    }
                    .frame(width: 40)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(song?.title ?? station.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                        Text(
                            song.map { "\($0.artistName) · \(station.name)" }
                                ?? StationText.waiting(station.onAir, kind: .music)
                        )
                        .font(.system(size: 12)).foregroundStyle(Theme.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            Button {
                Task { await player.stop() }
            } label: {
                Image(systemName: "stop.fill").font(.system(size: 20)).frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Stop")
        }
        .padding(.horizontal, 10)
    }
}

/// Now playing on a music station; off schedule, when it is back.
struct StationNowPlaying: View {
    @Environment(\.dismiss) private var dismiss
    @State private var showingUpNext = false
    let player: RabbitEarsKit.MusicPlayer
    let tuner: StationTuner

    var body: some View {
        let station = tuner.station
        let song = player.current
        ZStack {
            LinearGradient(
                colors: [(song.map { ArtPalette.color($0.albumId) } ?? Theme.card).opacity(0.55), Theme.ground],
                startPoint: .top, endPoint: .center
            )
            .ignoresSafeArea()
            VStack(spacing: 18) {
                header(station)
                if let song {
                    ArtSquare(id: song.albumId, radius: 14, placeholder: .album, badges: StatusBadges(id: song.id))
                        .shadow(color: .black.opacity(0.5), radius: 24, y: 12)
                    SongTitles(song: song)
                    progress(song)
                } else {
                    StationIdentity(
                        id: station.id, name: station.name, aspect: 1, radius: 14, imageUrl: station.imageUrl)
                    VStack(spacing: 4) {
                        Text(station.name).font(.system(size: 22, weight: .bold))
                        Text(StationText.waiting(station.onAir, kind: .music)).font(.system(size: 15))
                            .foregroundStyle(Theme.secondary)
                    }
                }
                stop
                Spacer(minLength: 0)
                HStack(spacing: 12) {
                    AirPlayButton().frame(width: 44, height: 44).accessibilityLabel("AirPlay")
                    Spacer(minLength: 0)
                    Button {
                        showingUpNext = true
                    } label: {
                        Label("Up next", systemImage: "list.bullet.indent").font(.system(size: 15, weight: .semibold))
                            .padding(.horizontal, 18).frame(height: 44).background(.white.opacity(0.12), in: .capsule)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 12)
        }
        .sheet(isPresented: $showingUpNext) {
            StationUpNextSheet(station: station).presentationDetents([.fraction(0.72), .large])
                .presentationBackground(Theme.raised)
        }
    }

    private func header(_ station: Station) -> some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.down").font(.system(size: 18, weight: .semibold))
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Close")
            Spacer()
            VStack(spacing: 1) {
                Text("Station").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                Text(station.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
            }
            Spacer()
            Color.clear.frame(width: 44, height: 44)
        }
    }

    private func progress(_ song: MusicSong) -> some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            let duration = Double(song.durationMs ?? 0) / 1000
            let position = Double(player.positionMs) / 1000
            VStack(spacing: 6) {
                ProgressBar(value: duration > 0 ? min(1, position / duration) : 0, height: 4)
                HStack {
                    Text(Format.clock(seconds: position))
                    Spacer()
                    Text("-" + Format.clock(seconds: max(0, duration - position)))
                }
                .font(.system(size: 12)).monospacedDigit().foregroundStyle(Theme.secondary)
            }
        }
    }

    private var stop: some View {
        Button {
            Task { await player.stop() }
        } label: {
            Image(systemName: "stop.fill").font(.system(size: 28)).foregroundStyle(Theme.ground)
                .frame(width: 72, height: 72).background(Theme.amber, in: .circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Stop")
    }
}

/// A music station's Up next, read only: the server sets the order.
struct StationUpNextSheet: View {
    let station: Station

    var body: some View {
        let songs = StationText.upNext(station.onAir)
        VStack(alignment: .leading, spacing: 4) {
            Text("Up next").font(.system(size: 22, weight: .bold)).accessibilityAddTraits(.isHeader)
            Text("On \(station.name). The station sets the order; songs cannot be skipped.")
                .font(.system(size: 13)).foregroundStyle(Theme.secondary)
            if songs.isEmpty {
                Text("Nothing is scheduled after this song.").foregroundStyle(Theme.secondary)
                    .frame(maxWidth: .infinity).padding(.top, 40)
                Spacer()
            } else {
                // A song can come round twice in one Up next, so rows are keyed by place.
                List(Array(songs.enumerated()), id: \.offset) { _, song in
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
                    .accessibilityElement(children: .combine)
                    .listRowBackground(Color.clear).listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
                }
                .listStyle(.plain).scrollContentBackground(.hidden)
            }
        }
        .padding(.horizontal, 20).padding(.top, 24)
        .foregroundStyle(Theme.primary)
    }
}
