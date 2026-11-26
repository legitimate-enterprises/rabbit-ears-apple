import RabbitEarsAPI
import RabbitEarsKit
import SwiftUI

extension Browser {
    func tune(_ station: Station, music: MusicPlayer, client: Client) {
        guard station.kind == .music else {
            tuning = station
            return
        }
        Task { await music.tune(StationTuner(client: client, station: station)) }
        if path.last != .nowPlaying { path.append(.nowPlaying) }
    }
}

struct StationGlyph: View {
    var size: CGFloat = 60

    var body: some View {
        RabbitEarsMark()
            .stroke(Theme.amber, style: StrokeStyle(lineWidth: max(3.5, size / 11), lineCap: .round, lineJoin: .round))
            .frame(width: size, height: size * 34 / 30)
            .accessibilityHidden(true)
    }
}

struct StationIdentity: View {
    let name: String
    var aspect: CGFloat = 16 / 9
    var imageUrl: String?

    var body: some View {
        if let imageUrl {
            ArtBlock(id: 0, aspect: aspect, url: imageUrl)
        } else {
            drawn
        }
    }

    private var drawn: some View {
        Theme.card.aspectRatio(aspect, contentMode: .fit)
            .overlay {
                VStack(spacing: 24) {
                    StationGlyph(size: 48)
                    Text(name).font(.system(size: 30, weight: .bold)).multilineTextAlignment(.center).lineLimit(2)
                }
                .padding(20)
            }
            .clipShape(.rect(cornerRadius: 12))
            .accessibilityHidden(true)
    }
}

struct StationArt: View {
    let station: Station

    var body: some View {
        let program = StationText.art(station.onAir)
        if station.imageUrl != nil {
            StationIdentity(name: station.name, aspect: station.kind == .music ? 1 : 16 / 9, imageUrl: station.imageUrl)
        } else if let song = program?.song {
            ArtBlock(id: song.albumId, placeholder: .album)
        } else if let item = program?.item {
            ArtBlock(item: item, aspect: 16 / 9)
        } else {
            StationIdentity(name: station.name, aspect: station.kind == .music ? 1 : 16 / 9)
        }
    }
}

/// A click tunes in, since a TV has no station page.
struct StationTile: View {
    @Environment(StationsModel.self) private var stations
    @Environment(MusicPlayer.self) private var music
    @Environment(Browser.self) private var browser
    let station: Station
    /// Home's On now: the name behind its kind, and how far through the program the station is.
    var onNow = false

    var body: some View {
        Button {
            browser.tune(station, music: music, client: stations.client)
        } label: {
            VStack(alignment: .leading, spacing: 14) {
                StationArt(station: station)
                    .overlay { if onNow { PlayBadge(size: 72) } }
                    .overlay(alignment: .bottom) {
                        if onNow, let fraction = StationText.onNowFraction(station.onAir) {
                            ProgressBar(value: fraction).padding(14)
                        }
                    }
                VStack(alignment: .leading, spacing: 2) {
                    Text(onNow ? StationText.onNowName(station) : station.name).font(
                        .system(size: 28, weight: .semibold)
                    ).lineLimit(1)
                    ForEach(StationText.lines(station.onAir, kind: station.kind), id: \.self) {
                        Text($0).font(.system(size: 26)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
        }
        .buttonStyle(CardButtonStyle())
        .labeled(onNow ? StationText.onNowLabel(station) : nil)
    }
}

struct StationTiles: View {
    @Environment(StationsModel.self) private var stations
    @Environment(Browser.self) private var browser
    let kind: PlaylistKind
    /// The parent's, which counts them beside the chips.
    @Binding var list: [Station]?

    static let wide = Array(repeating: GridItem(.fixed(410), spacing: 40, alignment: .top), count: 4)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let list {
                if list.isEmpty {
                    Text("No stations yet.").font(.system(size: 30)).foregroundStyle(Theme.secondary)
                        .frame(maxWidth: .infinity).padding(80)
                }
                LazyVGrid(columns: kind == .music ? GridView.columns : Self.wide, alignment: .leading, spacing: 50) {
                    ForEach(list) { StationTile(station: $0) }
                }
                .focusSection()
            } else if let error = stations.error {
                Text(error).font(.system(size: 30)).foregroundStyle(Theme.secondary)
                    .frame(maxWidth: .infinity).padding(80)
            } else {
                ProgressView().frame(maxWidth: .infinity).padding(80)
            }
        }
        .task(id: browser.returns) { list = await stations.list(kind) }
    }

    static func count(_ list: [Station]?) -> String {
        guard let list else { return "" }
        return Format.count(list.count, "station")
    }
}

struct OnNowShelf: View {
    @Environment(StationsModel.self) private var stations
    @Environment(Browser.self) private var browser
    @Environment(AppModel.self) private var app
    @State private var list: [Station] = []
    @State private var answered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if list.isEmpty, let slot = app.homeSlots(stations.profileId).onNow(answered: answered) {
                RowPlaceholder(slot: slot)
            } else if !list.isEmpty {
                VStack(alignment: .leading, spacing: 24) {
                    Text("On now").font(.system(size: 34, weight: .bold)).padding(.horizontal, 80)
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(alignment: .top, spacing: 40) {
                            ForEach(list) {
                                StationTile(station: $0, onNow: true).frame(width: $0.kind == .music ? 220 : 380)
                            }
                        }
                        .padding(.vertical, 20)
                    }
                    .contentMargins(.horizontal, 80, for: .scrollContent)
                    .scrollClipDisabled()
                }
                .focusSection()
            }
        }
        .task(id: browser.returns) {
            let all = await stations.list()
            guard !Task.isCancelled else { return }
            list = StationsModel.onNow(all ?? [])
            if all != nil { app.homeShowed(onNow: list, profileId: stations.profileId) }
            answered = true
        }
    }
}

/// Stop is the only control; nothing pauses or skips, so play/pause does nothing here.
struct StationNowPlaying: View {
    @Environment(MusicPlayer.self) private var player
    let tuner: StationTuner

    var body: some View {
        let station = tuner.station
        ZStack {
            NowPlayingGround()
            HStack(alignment: .top, spacing: 96) {
                playing(station).frame(width: 760, alignment: .leading)
                upNext(station).frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .padding(Theme.safeArea)
        }
        .foregroundStyle(Theme.light)
        .ignoresSafeArea()
        .onPlayPauseCommand {}
        .toolbar(.hidden, for: .navigationBar)
    }

    private func playing(_ station: Station) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                if let song = player.current {
                    ArtBlock(id: song.albumId, radius: 20, placeholder: .album)
                } else {
                    StationIdentity(name: station.name, aspect: 1, imageUrl: station.imageUrl)
                }
            }
            .frame(width: 500).shadow(color: .black.opacity(0.5), radius: 40, y: 20)
            if let song = player.current {
                TrackLines(title: song.title, artist: song.artistName, album: song.albumTitle).padding(.top, 32)
                if let program = station.onAir.now { clock(program).padding(.top, 28) }
            } else {
                TrackLines(title: station.name, artist: StationText.waiting(station.onAir, kind: .music), album: "")
                    .padding(.top, 32)
            }
            HStack(spacing: 28) {
                Button {
                    Task { await player.stop() }
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .buttonStyle(PlayerButtonStyle())
                Text("Play joins the station where it is.").font(.system(size: 28)).foregroundStyle(Theme.secondary)
            }
            .padding(.top, 24)
        }
    }

    /// Where every listener is; no knob, since nothing seeks.
    private func clock(_ program: StationProgram) -> some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let progress = StationText.progress(program, at: context.date)
            VStack(spacing: 8) {
                ProgressBar(value: progress.fraction, height: 8)
                    .accessibilityLabel("\(Int(progress.fraction * 100)) percent played")
                HStack {
                    Text(Format.clock(seconds: progress.elapsed))
                    Spacer()
                    Text("-" + Format.clock(seconds: progress.remaining))
                }
                .font(.system(size: 30)).monospacedDigit()
            }
        }
    }

    private func upNext(_ station: Station) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Up next").font(.system(size: 52, weight: .bold))
            Text("On \(station.name). The station sets the order; songs cannot be skipped.").font(.system(size: 30))
                .foregroundStyle(Theme.secondary).padding(.top, 4).padding(.bottom, 28)
            // A song can come round twice in one Up next, so rows are keyed by place.
            ForEach(Array(StationText.upNext(station.onAir).enumerated()), id: \.offset) { index, song in
                HStack(spacing: 24) {
                    Text("\(index + 1)").foregroundStyle(Theme.secondary).frame(width: 56, alignment: .trailing)
                    let title = Text(song.title).font(.system(size: 32, weight: .semibold))
                    let artist = Text("· \(song.artistName)").foregroundStyle(Theme.secondary)
                    Text("\(title) \(artist)").lineLimit(1)
                    Spacer(minLength: 20)
                    Text(song.durationMs.map { Format.clock(seconds: Double($0) / 1000) } ?? "")
                        .foregroundStyle(Theme.secondary).monospacedDigit()
                }
                .font(.system(size: 30))
                .padding(.vertical, 18)
            }
        }
    }
}
