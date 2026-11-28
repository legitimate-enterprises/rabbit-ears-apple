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
    var radius: CGFloat = 6
    var imageUrl: String?

    var body: some View {
        if let imageUrl {
            Art(id: id, aspect: aspect, radius: radius, url: imageUrl, badged: false)
        } else {
            drawn
        }
    }

    private var drawn: some View {
        Theme.card.aspectRatio(aspect, contentMode: .fit)
            .overlay {
                VStack(spacing: 8) {
                    StationGlyph()
                    Text(name).font(.system(size: 13, weight: .bold)).multilineTextAlignment(.center).lineLimit(2)
                }
                .padding(10)
            }
            .clipShape(.rect(cornerRadius: radius))
            .accessibilityHidden(true)
    }
}

/// The station's own image, else what is on, else what is next, else its
/// own tile; square for music.
struct StationArt: View {
    let station: Station
    var radius: CGFloat = 6

    var body: some View {
        let program = StationText.art(station.onAir)
        if station.imageUrl != nil {
            StationIdentity(
                id: station.id, name: station.name, aspect: station.kind == .music ? 1 : 16 / 9, radius: radius,
                imageUrl: station.imageUrl)
        } else if let song = program?.song {
            Art(id: song.albumId, radius: radius, placeholder: .album, badged: false)
        } else if let item = program?.item {
            ArtBlock(item: item, aspect: 16 / 9, radius: radius, badged: false)
        } else {
            StationIdentity(
                id: station.id, name: station.name, aspect: station.kind == .music ? 1 : 16 / 9, radius: radius)
        }
    }
}

struct StationTile: View {
    @Environment(AppModel.self) private var app
    @Environment(MusicPlayer.self) private var music: MusicPlayer?
    @Environment(Browser.self) private var browser
    let station: Station
    /// Home's On now: the name behind its kind, how far through the program the station is, and a
    /// click tunes in; the context menu goes to the station.
    var onNow = false

    var body: some View {
        Button {
            if onNow {
                browser.tune(station, music: music, app: app)
            } else {
                browser.open(.station(station.id))
            }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                StationArt(station: station)
                    .overlay { if onNow { PlayBadge() } }
                    .overlay(alignment: .bottom) {
                        if onNow, let fraction = StationText.onNowFraction(station.onAir) {
                            ProgressBar(value: fraction).padding(6)
                        }
                    }
                    .padding(.bottom, 2)
                Text(onNow ? StationText.onNowName(station) : station.name)
                    .font(.system(size: 12, weight: .semibold)).lineLimit(1)
                ForEach(Array(StationText.lines(station.onAir, kind: station.kind).enumerated()), id: \.offset) {
                    Text($0.element).font(.system(size: 11)).lineLimit(1)
                        .foregroundStyle($0.offset == 0 ? Theme.synopsis : Theme.secondary)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .labeled(onNow ? StationText.onNowLabel(station) : nil)
        .contextMenu {
            if onNow { Button("Go to details") { browser.open(.station(station.id)) } }
        }
    }
}

struct StationGrid: View {
    @Environment(StationsModel.self) private var stations
    @Environment(AppModel.self) private var app
    @Environment(Browser.self) private var browser
    let kind: PlaylistKind
    @State private var list: [Station]?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if app.isAdult {
                Button {
                    browser.editingStation = StationEditRequest(kind: kind)
                } label: {
                    Label("New station", systemImage: "plus")
                }
                .buttonStyle(SecondaryButtonStyle())
            }
            if let list {
                if list.isEmpty { Text("No stations yet.").foregroundStyle(Theme.secondary) }
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: kind == .music ? 150 : 220), spacing: 14, alignment: .top)],
                    spacing: 18
                ) {
                    ForEach(list) { StationTile(station: $0) }
                }
            } else if let error = stations.error {
                Text(error).foregroundStyle(Theme.secondary)
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .task(id: browser.revision) { list = await stations.list(kind) }
    }
}

struct StationsScreen: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                ForEach([PlaylistKind.movies, .tv, .music], id: \.self) { kind in
                    VStack(alignment: .leading, spacing: 12) {
                        Heading(text: kind == .movies ? "Movies" : kind == .tv ? "TV" : "Music")
                        StationGrid(kind: kind)
                    }
                }
            }
            .padding(EdgeInsets(top: 10, leading: 22, bottom: 24, trailing: 22))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct OnNowStrip: View {
    @Environment(StationsModel.self) private var stations
    @Environment(Browser.self) private var browser
    @Environment(AppModel.self) private var app
    @State private var list: [Station] = []
    @State private var answered = false

    var body: some View {
        Group {
            if list.isEmpty, let slot = app.homeSlots(stations.profileId).onNow(answered: answered) {
                RowPlaceholder(slot: slot)
            } else if !list.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("On now").font(.system(size: 15, weight: .bold))
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 14) {
                            ForEach(list) {
                                StationTile(station: $0, onNow: true).frame(width: $0.kind == .music ? 126 : 224)
                            }
                        }
                    }
                }
            }
        }
        .task(id: browser.revision) {
            let all = await stations.list()
            guard !Task.isCancelled else { return }
            list = StationsModel.onNow(all ?? [])
            if all != nil { app.homeShowed(onNow: list, profileId: stations.profileId) }
            answered = true
        }
    }
}

/// A station's owner also sees and edits what it holds, as on a playlist.
struct StationScreen: View {
    @Environment(StationsModel.self) private var stations
    @Environment(PlaylistsModel.self) private var playlists: PlaylistsModel?
    @Environment(MusicPlayer.self) private var music: MusicPlayer?
    @Environment(AppModel.self) private var app
    @Environment(Browser.self) private var browser
    let id: UID
    @State private var station: Station?
    @State private var programs: [StationProgram]?
    @State private var entries: [PlaylistEntry]?
    @State private var failed = false

    var body: some View {
        Group {
            if let station {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        header(station)
                        Heading(text: "Today")
                        schedule(station)
                        if app.isAdult && stations.isOwner(station), playlists != nil { contents(station) }
                    }
                    .padding(EdgeInsets(top: 18, leading: 22, bottom: 24, trailing: 22))
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .pageTitle(station.name)
            } else if failed {
                ContentUnavailableView("Not available", systemImage: "questionmark.square.dashed")
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: "\(id)/\(browser.revision)") {
            station = await stations.station(id)
            failed = station == nil
            programs = await stations.schedule(of: id)
            if let station, stations.isOwner(station) { entries = await playlists?.entries(of: station.playlistId) }
        }
    }

    @ViewBuilder
    private func contents(_ station: Station) -> some View {
        Heading(text: "In this station")
        if let entries {
            if entries.isEmpty {
                Text("Nothing here yet. Add to it from any title's menu.").foregroundStyle(Theme.secondary)
            } else {
                PlaylistEntryList(
                    playlistId: station.playlistId,
                    entries: Binding(get: { entries }, set: { self.entries = $0 }),
                    // A station's own playlist is listed nowhere and is the owner's to edit, unless rules choose it.
                    editable: playlists?.playlists.first { $0.id == station.playlistId }?.isEditable
                        ?? (station.smart != true)
                )
                .frame(height: CGFloat(entries.count) * 64)
            }
        } else {
            ProgressView().frame(maxWidth: .infinity)
        }
    }

    private func header(_ station: Station) -> some View {
        HStack(alignment: .top, spacing: 22) {
            StationIdentity(
                id: station.id, name: station.name, aspect: station.kind == .music ? 1 : 16 / 9, radius: 10,
                imageUrl: station.imageUrl
            )
            .frame(width: station.kind == .music ? 140 : 250)
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Text(station.name).font(.system(size: 26, weight: .bold))
                    if station.smart == true { SmartBadge() }
                }
                Flow {
                    Text(StationText.kind(station.kind))
                    Tag(text: StationText.rating(station)).foregroundStyle(Theme.primary)
                    Text(StationText.visibility(station.visibility))
                    Text(station.order == .random ? "Shuffled" : "In order")
                }
                .font(.system(size: 13)).foregroundStyle(Theme.secondary)
                Flow {
                    Button {
                        browser.tune(station, music: music, app: app)
                    } label: {
                        Label("Tune in", systemImage: "play.fill")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    if app.isAdult && stations.isOwner(station) {
                        Button("Edit station") { browser.editingStation = StationEditRequest(station: station) }
                            .buttonStyle(SecondaryButtonStyle())
                        StationRulesButton(station: station)
                        Button("Set image…") {
                            browser.imaging = ImageRequest(station: station)
                        }
                        .buttonStyle(SecondaryButtonStyle())
                        if station.imageUrl != nil {
                            Button("Remove image") {
                                Task {
                                    if await CustomImageModel(client: stations.client).remove(
                                        from: .station(station.id))
                                    {
                                        browser.revision += 1
                                    }
                                }
                            }
                            .buttonStyle(SecondaryButtonStyle())
                        }
                    }
                }
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(StationText.summary(station.onAir, kind: station.kind, now: context.date))
                        .font(.system(size: 13)).foregroundStyle(Theme.synopsis)
                }
            }
        }
    }

    @ViewBuilder
    private func schedule(_ station: Station) -> some View {
        if let programs {
            if programs.isEmpty { Text("Nothing scheduled today.").foregroundStyle(Theme.secondary) }
            TimelineView(.periodic(from: .now, by: 30)) { context in
                VStack(spacing: 0) {
                    ForEach(programs, id: \.startsAt) { program in
                        row(program, now: context.date)
                    }
                }
            }
        } else {
            ProgressView().frame(maxWidth: .infinity)
        }
    }

    private func row(_ program: StationProgram, now: Date) -> some View {
        let onNow = program.startsAt <= now && now < program.endsAt
        let past = program.endsAt <= now
        return HStack(spacing: 16) {
            Text(StationText.time(program.startsAt)).frame(width: 74, alignment: .leading)
                .foregroundStyle(onNow ? Theme.amber : Theme.secondary)
            Text(StationText.title(program)).fontWeight(.semibold).lineLimit(1)
                .foregroundStyle(onNow ? Theme.amber : past ? Theme.secondary : Theme.primary)
            if onNow {
                Text("On now").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.amber)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Theme.amber.opacity(0.16), in: .rect(cornerRadius: 4))
            }
            Spacer()
            Text(Format.runtime(minutes: Int((program.durationMs + 30_000) / 60_000)))
                .foregroundStyle(Theme.secondary)
        }
        .font(.system(size: 13))
        .padding(.vertical, 7).padding(.horizontal, 10)
    }
}

/// Nothing for a kid, who owns no stations.
struct StationMenu: View {
    @Environment(StationsModel.self) private var stations: StationsModel?
    @Environment(PlaylistsModel.self) private var playlists: PlaylistsModel?
    @Environment(Browser.self) private var browser
    var itemId: UID?
    var editionId: UID?
    var collectionId: UID?
    let kind: PlaylistKind
    var asButton = false

    var body: some View {
        if let stations, let playlists, playlists.adult {
            if asButton {
                Menu {
                    choices(stations.mine(kind), playlists)
                } label: {
                    Text("Add to station")
                }
                .menuStyle(.button).menuIndicator(.hidden).buttonStyle(SecondaryButtonStyle()).fixedSize()
            } else {
                Menu("Add to station") { choices(stations.mine(kind), playlists) }
            }
        }
    }

    @ViewBuilder
    private func choices(_ mine: [Station], _ playlists: PlaylistsModel) -> some View {
        ForEach(mine) { station in
            Button(station.name) {
                Task {
                    if await playlists.add(
                        item: itemId, edition: editionId, collection: collectionId, to: station.playlistId)
                    {
                        browser.rescheduling = station
                    }
                    browser.revision += 1
                }
            }
        }
        if !mine.isEmpty { Divider() }
        Button("New station…") {
            browser.editingStation = StationEditRequest(
                kind: kind, itemId: itemId, editionId: editionId, collectionId: collectionId)
        }
    }
}
