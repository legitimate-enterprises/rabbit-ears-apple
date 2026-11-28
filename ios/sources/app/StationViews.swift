import RabbitEarsAPI
import RabbitEarsKit
import SwiftUI

struct StationGlyph: View {
    var size: CGFloat = 22

    var body: some View {
        StationMark()
            .stroke(Theme.amber, style: StrokeStyle(lineWidth: max(1.5, size / 11), lineCap: .round, lineJoin: .round))
            .frame(width: size, height: size * 0.9)
            .accessibilityHidden(true)
    }
}

/// A station's own tile: the image its owner set, else drawn from its name.
struct StationIdentity: View {
    let id: UID
    let name: String
    var aspect: CGFloat = 16 / 9
    var radius: CGFloat = 8
    var imageUrl: String?

    var body: some View {
        if let imageUrl {
            ArtSquare(id: id, aspect: aspect, radius: radius, url: imageUrl, badged: false)
        } else {
            drawn
        }
    }

    private var drawn: some View {
        Theme.card.aspectRatio(aspect, contentMode: .fit)
            .overlay {
                VStack(spacing: 6) {
                    StationGlyph()
                    Text(name).font(.system(size: 12, weight: .bold)).multilineTextAlignment(.center).lineLimit(2)
                        .foregroundStyle(Theme.primary)
                }
                .padding(8)
            }
            .clipShape(.rect(cornerRadius: radius))
            .accessibilityHidden(true)
    }
}

/// The station's own image, else what is on, else what is next, else its
/// own tile; square for music.
struct StationArt: View {
    let station: Station
    var radius: CGFloat = 8

    var body: some View {
        let program = StationText.art(station.onAir)
        if station.imageUrl != nil {
            StationIdentity(
                id: station.id, name: station.name, aspect: station.kind == .music ? 1 : 16 / 9, radius: radius,
                imageUrl: station.imageUrl)
        } else if let song = program?.song {
            ArtSquare(id: song.albumId, radius: radius, placeholder: .album, badged: false)
        } else if let item = program?.item {
            ArtBlock(item: item, aspect: 16 / 9, radius: radius, badged: false)
        } else {
            StationIdentity(
                id: station.id, name: station.name, aspect: station.kind == .music ? 1 : 16 / 9, radius: radius)
        }
    }
}

/// A library's Stations chip: New station for an adult, then that kind's stations as rows.
struct StationsList: View {
    @Environment(Services.self) private var services
    @Environment(AppModel.self) private var app
    @Environment(Browser.self) private var browser
    let kind: PlaylistKind
    @Binding var count: String
    @State private var list: [Station]?

    var body: some View {
        LazyVStack(spacing: 12) {
            if app.activeProfile?.kind == .adult {
                Button {
                    browser.editingStation = StationEditRequest(kind: kind)
                } label: {
                    Label("New station", systemImage: "plus").font(.system(size: 15, weight: .semibold))
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
                }
                .buttonStyle(.plain).foregroundStyle(Theme.amber)
            }
            if let list {
                ForEach(list) { row($0) }
                if list.isEmpty { EmptyNote(text: "No stations yet.") }
            } else if let error = services.stations.error {
                Text(error).font(.system(size: 13)).foregroundStyle(Theme.error)
            } else {
                ProgressView().frame(maxWidth: .infinity).padding(40)
            }
        }
        .task(id: browser.revision) { await load() }
        .reloads { await load() }
    }

    /// A list the server could not answer keeps what it showed.
    private func load() async {
        guard let loaded = await services.stations.list(kind) else { return }
        list = loaded
        count = loaded.count.formatted()
    }

    private func row(_ station: Station) -> some View {
        Button {
            browser.open(.station(station.id))
        } label: {
            HStack(spacing: 14) {
                StationArt(station: station).frame(width: station.kind == .music ? 76 : 136)
                VStack(alignment: .leading, spacing: 2) {
                    Text(station.name).font(.system(size: 16, weight: .semibold)).lineLimit(1)
                    ForEach(Array(StationText.lines(station.onAir, kind: station.kind).enumerated()), id: \.offset) {
                        Text($0.element).font(.system(size: 13)).lineLimit(1)
                            .foregroundStyle($0.offset == 0 ? Theme.synopsis : Theme.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

/// Home's On now row: every station with something on, after Next up; absent when none is.
struct OnNowStrip: View {
    @Environment(Services.self) private var services
    @Environment(AppModel.self) private var app
    @Environment(Browser.self) private var browser
    let list: [Station]

    var body: some View {
        if !list.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("On now").font(.system(size: 20, weight: .bold))
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(list) { tile($0).frame(width: $0.kind == .music ? 110 : 170) }
                    }
                }
                .contentMargins(.horizontal, 20, for: .scrollContent)
                .padding(.horizontal, -20)
            }
        }
    }

    private func tile(_ station: Station) -> some View {
        Button {
            browser.tune(station, music: services.player, app: app)
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                StationArt(station: station)
                    .overlay { PlayBadge() }
                    .overlay(alignment: .bottom) {
                        if let fraction = StationText.onNowFraction(station.onAir) {
                            ProgressBar(value: fraction, height: 4)
                        }
                    }
                VStack(alignment: .leading, spacing: 1) {
                    Text(StationText.onNowName(station)).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    if let now = station.onAir.now {
                        Text(StationText.title(now)).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                            .lineLimit(2, reservesSpace: true)
                    }
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(StationText.onNowLabel(station))
        .contextMenu {
            Button("Go to details", systemImage: "info.circle") { browser.open(.station(station.id)) }
        }
    }
}
