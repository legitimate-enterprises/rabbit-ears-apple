import RabbitEarsAPI
import RabbitEarsKit
import SwiftUI

/// What an Add to playlist or Add to station sheet adds, and of which kind.
struct PlaylistTarget: Identifiable {
    let id = UUID()
    let itemIds: [UID]
    let kind: PlaylistKind
    /// The edition chosen on details; nil asks the server, which may ask the adult.
    var editionId: UID?
    /// A collection, added as one entry of a movies playlist or station.
    var collectionId: UID?
    /// Into one of the profile's stations of `kind`, whose playlist holds what it plays.
    var station = false
}

extension View {
    func addToPlaylist(_ target: Binding<PlaylistTarget?>) -> some View {
        sheet(item: target) { AddToPlaylistSheet(target: $0).presentationDetents([.medium, .large]) }
    }
}

/// Add to playlist and Add to station, for a menu; adults only, since kids have neither.
struct AddToButtons: View {
    @Environment(AppModel.self) private var app
    @Binding var target: PlaylistTarget?
    let itemIds: [UID]
    let kind: PlaylistKind
    var editionId: UID?
    var collectionId: UID?

    var body: some View {
        if app.activeProfile?.kind == .adult {
            Button("Add to playlist", systemImage: "text.badge.plus") { pick(station: false) }
            Button("Add to station", systemImage: "dot.radiowaves.left.and.right") { pick(station: true) }
        }
    }

    private func pick(station: Bool) {
        target = PlaylistTarget(
            itemIds: itemIds, kind: kind, editionId: editionId, collectionId: collectionId, station: station)
    }
}

struct AddToPlaylistSheet: View {
    @Environment(Services.self) private var services
    @Environment(\.dismiss) private var dismiss
    let target: PlaylistTarget
    @State private var naming = false
    @State private var name = ""
    @State private var newStation: StationEditRequest?
    @State private var rescheduling: Station?
    /// The existing station being added to, asked to reschedule once a Which edition? answer adds.
    @State private var addingTo: Station?

    var body: some View {
        let playlists = services.playlists
        NavigationStack {
            List {
                if target.station { stations } else { lists }
                if let error = playlists.error ?? (target.station ? services.stations.error : nil) {
                    Text(error).foregroundStyle(Theme.error).font(.system(size: 13))
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.raised)
            .navigationTitle(target.station ? "Add to station" : "Add to playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .alert("New playlist", isPresented: $naming) {
                TextField("Name", text: $name)
                Button("Cancel", role: .cancel) { name = "" }
                Button("Create") {
                    let chosen = name
                    name = ""
                    Task {
                        if let playlist = await playlists.create(name: chosen, kind: target.kind),
                            await add(to: playlist.id)
                        {
                            dismiss()
                        }
                    }
                }
            }
        }
        .foregroundStyle(Theme.primary)
        .sheet(item: $newStation) { StationEditor(request: $0) }
        .rescheduleQuestion($rescheduling, services.stations) { dismiss() }
        .task { if target.station { await services.stations.loadMine() } }
        .confirmationDialog(
            "Which edition?",
            isPresented: Binding(
                get: { playlists.editionQuestion != nil }, set: { if !$0 { playlists.editionQuestion = nil } }),
            titleVisibility: .visible, presenting: playlists.editionQuestion
        ) { question in
            ForEach(question.editions, id: \.id) { edition in
                Button(Editions.label(edition)) {
                    Task {
                        guard await playlists.answer(question, with: edition) else { return }
                        if let addingTo { rescheduling = addingTo } else { dismiss() }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var lists: some View {
        Button("New playlist", systemImage: "plus") { naming = true }
        ForEach(services.playlists.editable(target.kind), id: \.id) { playlist in
            choice(playlist.name, PlaylistText.summary(playlist)) { if await add(to: playlist.id) { dismiss() } }
        }
    }

    @ViewBuilder
    private var stations: some View {
        Button("New station", systemImage: "plus") {
            newStation = StationEditRequest(kind: target.kind) { made in
                Task { if await add(to: made.playlistId) { dismiss() } }
            }
        }
        ForEach(services.stations.mine(target.kind)) { station in
            choice(station.name, StationText.visibility(station.visibility)) {
                addingTo = station
                if await add(to: station.playlistId) { rescheduling = station }
            }
        }
    }

    private func choice(_ title: String, _ detail: String, _ action: @escaping () async -> Void) -> some View {
        Button {
            Task { await action() }
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 15, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(Theme.secondary)
            }
        }
    }

    /// Whether everything went in; a title of several editions without one
    /// chosen stops here for the question.
    private func add(to playlistId: UID) async -> Bool {
        // A selection goes in one request, each title of several editions as its default.
        if target.itemIds.count > 1 {
            return await services.playlists.add(target.itemIds, to: playlistId)
        }
        for id in target.itemIds {
            guard await services.playlists.add(id, to: playlistId, edition: target.editionId) else { return false }
        }
        if let collection = target.collectionId {
            guard await services.playlists.add(collection: collection, to: playlistId) else { return false }
        }
        return true
    }
}
