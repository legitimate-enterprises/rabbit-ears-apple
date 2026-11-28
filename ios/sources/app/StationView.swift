import RabbitEarsAPI
import RabbitEarsKit
import SwiftUI

struct StationView: View {
    @Environment(Services.self) private var services
    @Environment(AppModel.self) private var app
    @Environment(Browser.self) private var browser
    let id: UID
    @State private var station: Station?
    @State private var programs: [StationProgram]?
    @State private var entries: [PlaylistEntry]?
    @State private var failed = false
    @State private var editing = EditMode.inactive
    @State private var imaging: ImageRequest?

    var body: some View {
        Group {
            if let station {
                List {
                    Group {
                        header(station)
                        heading("Today")
                        schedule
                        if owns(station) { heading("Contents") }
                        if owns(station), entries?.isEmpty == true {
                            EmptyNote(text: "Nothing here yet. Add from any title's More menu.")
                        }
                    }
                    .listRowBackground(Color.clear).listRowSeparator(.hidden)
                    if owns(station), let entries {
                        // A station's own playlist is listed nowhere and is the owner's to edit unless it is smart.
                        PlaylistEntryRows(
                            playlistId: station.playlistId, entries: entries,
                            editable: services.playlists.playlists.first { $0.id == station.playlistId }?.isEditable
                                ?? (station.smart != true)
                        ) { self.entries = $0 }
                    }
                }
                .listStyle(.plain).scrollContentBackground(.hidden)
                .environment(\.editMode, $editing)
            } else if failed {
                ContentUnavailableView("Not available", systemImage: "questionmark.square.dashed")
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Theme.ground)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let station, owns(station), station.smart != true {
                ToolbarItem(placement: .topBarTrailing) { EditButton() }
            }
            BrowseToolbar()
        }
        .imageSheet($imaging, playlists: services.playlists) { await reload() }
        .task(id: "\(id)/\(browser.revision)") {
            station = await services.stations.station(id)
            failed = station == nil
            if let station, owns(station) { entries = await services.playlists.entries(of: station.playlistId) }
            programs = await services.stations.schedule(of: id)
        }
    }

    private func reload() async { station = await services.stations.station(id) ?? station }

    /// Only the owner reads a station's own playlist, as only they edit it.
    private func owns(_ station: Station) -> Bool {
        app.activeProfile?.kind == .adult && services.stations.isOwner(station)
    }

    private func heading(_ text: String) -> some View {
        Text(text).font(.system(size: 20, weight: .bold)).accessibilityAddTraits(.isHeader).padding(.top, 6)
    }

    private func header(_ station: Station) -> some View {
        VStack(spacing: 12) {
            StationIdentity(
                id: station.id, name: station.name, aspect: station.kind == .music ? 1 : 16 / 9, radius: 10,
                imageUrl: station.imageUrl
            )
            .frame(width: station.kind == .music ? 160 : 240)
            Text(station.name).font(.system(size: 26, weight: .bold)).multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            if station.smart == true { SmartBadge() }
            HStack(spacing: 10) {
                Text(StationText.kind(station.kind))
                Tag(text: StationText.rating(station))
                Text(StationText.visibility(station.visibility))
            }
            .font(.system(size: 13)).foregroundStyle(Theme.secondary)
            HStack(spacing: 10) {
                Button {
                    browser.tune(station, music: services.player, app: app)
                } label: {
                    Label("Tune in", systemImage: "play.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryButtonStyle(fullWidth: true))
                if owns(station) {
                    Button {
                        browser.editingStation = StationEditRequest(station: station)
                    } label: {
                        Text("Edit station").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(SecondaryButtonStyle(fullWidth: true))
                    StationRulesButton(station: station)
                    Menu {
                        ImageActions(
                            request: ImageRequest(station: station),
                            client: services.stations.client, imaging: $imaging
                        ) { await reload() }
                    } label: {
                        Image(systemName: "photo").accessibilityLabel("Image")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
            }
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text(StationText.summary(station.onAir, kind: station.kind, now: context.date))
                    .font(.system(size: 13)).foregroundStyle(Theme.synopsis).multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var schedule: some View {
        if let programs {
            if programs.isEmpty { EmptyNote(text: "Nothing scheduled today.") }
            TimelineView(.periodic(from: .now, by: 30)) { context in
                LazyVStack(spacing: 0) {
                    ForEach(programs, id: \.startsAt) { row($0, now: context.date) }
                }
            }
        } else if let error = services.stations.error {
            Text(error).font(.system(size: 13)).foregroundStyle(Theme.error)
        } else {
            ProgressView().frame(maxWidth: .infinity)
        }
    }

    private func row(_ program: StationProgram, now: Date) -> some View {
        let onNow = program.startsAt <= now && now < program.endsAt
        let past = program.endsAt <= now
        return HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(StationText.time(program.startsAt)).frame(width: 74, alignment: .leading)
                .foregroundStyle(onNow ? Theme.amber : Theme.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(StationText.title(program)).fontWeight(.semibold).lineLimit(1)
                    .foregroundStyle(onNow ? Theme.amber : past ? Theme.secondary : Theme.primary)
                if onNow {
                    let left = Int64(program.endsAt.timeIntervalSince(now) * 1000)
                    Text("On now, \(Format.remaining(ms: max(0, left)))").font(.system(size: 12))
                        .foregroundStyle(Theme.amber)
                }
            }
            Spacer(minLength: 0)
            Text(Format.runtime(minutes: Int((program.durationMs + 30_000) / 60_000)))
                .foregroundStyle(Theme.secondary)
        }
        .font(.system(size: 15))
        .padding(.vertical, 8)
        .fontWeight(onNow ? .semibold : .regular)
    }
}
