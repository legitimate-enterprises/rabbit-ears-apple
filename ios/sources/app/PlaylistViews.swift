import RabbitEarsAPI
import RabbitEarsKit
import SwiftUI

/// The profile's playlists of one kind and those shared with it.
struct PlaylistsList: View {
    @Environment(Services.self) private var services
    @Environment(Browser.self) private var browser
    let kind: PlaylistKind
    @Binding var count: String
    @State private var naming = false
    @State private var name = ""
    @State private var renaming: Playlist?
    @State private var deleting: Playlist?
    @State private var sharing: Playlist?
    @State private var imaging: ImageRequest?

    var body: some View {
        let playlists = services.playlists.playlists(kind)
        LazyVStack(spacing: 4) {
            if services.playlists.adult {
                Button {
                    naming = true
                } label: {
                    Label("New playlist", systemImage: "plus").font(.system(size: 15, weight: .semibold))
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
                }
                .buttonStyle(.plain).foregroundStyle(Theme.amber)
                Button {
                    browser.smartRules = SmartRulesRequest(target: .newPlaylist(kind))
                } label: {
                    Label("New smart playlist", systemImage: "sparkles").font(.system(size: 15, weight: .semibold))
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
                }
                .buttonStyle(.plain).foregroundStyle(Theme.amber)
            }
            ForEach(playlists, id: \.id) { playlist in
                Button {
                    browser.open(.playlist(playlist.id))
                } label: {
                    HStack(spacing: 12) {
                        if playlist.imageUrl != nil || playlist.artItemId != nil {
                            ArtSquare(
                                id: playlist.artItemId ?? playlist.id, radius: 6, url: playlist.imageUrl,
                                placeholder: .playlist,
                                badges: StatusBadges(id: playlist.id, scope: .playlist, shared: playlist.isShared)
                            )
                            .frame(width: 48)
                        } else {
                            Image(systemName: kind == .music ? "music.note.list" : "list.and.film")
                                .frame(width: 48, height: 48).background(Theme.raised, in: .rect(cornerRadius: 6))
                                .overlay(alignment: .bottomTrailing) {
                                    StatusBadges(id: playlist.id, scope: .playlist, shared: playlist.isShared)
                                }
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(playlist.name).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                            Text(PlaylistText.summary(playlist)).font(.system(size: 12))
                                .foregroundStyle(Theme.secondary)
                            if let shared = playlist.sharedBy {
                                Text(shared).font(.system(size: 12)).foregroundStyle(Theme.secondary).lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.secondary)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .contextMenu {
                    DownloadMenu(.playlist(playlist))
                    if playlist.isOwned {
                        if playlist.smart == true {
                            Button("Edit rules", systemImage: "sparkles") {
                                browser.smartRules = SmartRulesRequest(target: .playlist(playlist))
                            }
                        }
                        Button("Share", systemImage: "person.2") { sharing = playlist }
                        Button("Rename", systemImage: "pencil") {
                            name = playlist.name
                            renaming = playlist
                        }
                        ImageActions(
                            request: ImageRequest(playlist: playlist, profileId: services.playlists.profileId),
                            client: services.playlists.client, imaging: $imaging
                        ) { await services.playlists.load() }
                        Button("Delete", systemImage: "trash", role: .destructive) { deleting = playlist }
                    }
                }
            }
            if playlists.isEmpty { EmptyNote(text: "No playlists yet.") }
            if let error = services.playlists.error { Text(error).font(.system(size: 13)).foregroundStyle(Theme.error) }
        }
        .task { await services.playlists.load() }
        .sheet(
            item: $sharing, onDismiss: { Task { await services.playlists.load() } },
            content: { PlaylistShareSheet(playlists: services.playlists, playlist: $0) }
        )
        .imageSheet($imaging, playlists: services.playlists) { await services.playlists.load() }
        .onAppear { count = playlists.count.formatted() }
        .onChange(of: playlists.count) { count = playlists.count.formatted() }
        .alert("New playlist", isPresented: $naming) {
            TextField("Name", text: $name)
            Button("Cancel", role: .cancel) { name = "" }
            Button("Create") {
                let chosen = name
                name = ""
                Task { _ = await services.playlists.create(name: chosen, kind: kind) }
            }
        }
        .alert("Rename playlist", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $name)
            Button("Cancel", role: .cancel) { renaming = nil }
            Button("Rename") {
                if let renaming { Task { await services.playlists.rename(renaming, to: name) } }
                renaming = nil
            }
        }
        .confirmationDialog(
            "Delete “\(deleting?.name ?? "")”?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let deleting { Task { await delete(deleting) } }
                deleting = nil
            }
        }
    }
}

extension PlaylistsList {
    /// A playlist a station plays is refused; the alert says why.
    private func delete(_ playlist: Playlist) async {
        if await services.playlists.delete(playlist) == false { browser.alert = services.playlists.error }
    }
}

/// One playlist: a show or album is one row, and play goes through the
/// server's play order.
struct PlaylistView: View {
    @Environment(Services.self) private var services
    @Environment(Browser.self) private var browser
    @Environment(\.dismiss) private var dismiss
    let id: UID
    @State private var entries: [PlaylistEntry]?
    @State private var editing = EditMode.inactive
    @State private var deleting = false
    @State private var sharing = false
    @State private var imaging: ImageRequest?

    var body: some View {
        let playlist = services.playlists.playlists.first { $0.id == id }
        let editable = services.playlists.adult && playlist?.isEditable == true
        VStack(alignment: .leading, spacing: 12) {
            if let playlist {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 10) {
                        Text(playlist.name).font(.system(size: 26, weight: .bold)).accessibilityAddTraits(.isHeader)
                        if playlist.smart == true { SmartBadge() }
                    }
                    Text(PlaylistText.summary(playlist)).font(.system(size: 13)).foregroundStyle(Theme.secondary)
                    if let shared = playlist.sharedBy {
                        Text(shared).font(.system(size: 13)).foregroundStyle(Theme.secondary)
                    }
                }
                .padding(.horizontal, 16)
                if let entries, !entries.isEmpty {
                    PlayShuffle(
                        play: { play(playlist, from: nil, shuffled: false) },
                        shuffle: playlist.kind == .music ? { play(playlist, from: nil, shuffled: true) } : nil
                    )
                    .padding(.horizontal, 16)
                }
            }
            if let entries {
                if entries.isEmpty {
                    EmptyNote(text: "Nothing in this playlist yet.")
                } else {
                    list(entries, playlist, editable: editable)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity).padding(40)
            }
            Spacer(minLength: 0)
        }
        .background(Theme.ground)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if editable { ToolbarItem(placement: .topBarTrailing) { EditButton() } }
            if let playlist {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        DownloadMenu(.playlist(playlist))
                        if playlist.isOwned && playlist.smart == true {
                            Button("Edit rules", systemImage: "sparkles") {
                                browser.smartRules = SmartRulesRequest(target: .playlist(playlist))
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .accessibilityLabel("More")
                }
            }
            if playlist?.isOwned == true {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Share playlist", systemImage: "person.2") { sharing = true }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu("Image", systemImage: "photo") {
                        if let playlist {
                            ImageActions(
                                request: ImageRequest(playlist: playlist, profileId: services.playlists.profileId),
                                client: services.playlists.client, imaging: $imaging
                            ) { await services.playlists.load() }
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Delete playlist", systemImage: "trash", role: .destructive) { deleting = true }
                }
            }
        }
        .sheet(
            isPresented: $sharing, onDismiss: { Task { await services.playlists.load() } },
            content: {
                if let playlist { PlaylistShareSheet(playlists: services.playlists, playlist: playlist) }
            }
        )
        .imageSheet($imaging, playlists: services.playlists) { await services.playlists.load() }
        .environment(\.editMode, $editing)
        .confirmationDialog("Delete this playlist?", isPresented: $deleting, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                guard let playlist else { return }
                Task {
                    if await services.playlists.delete(playlist) {
                        dismiss()
                    } else {
                        browser.alert = services.playlists.error
                    }
                }
            }
        }
        .task(id: "\(id)/\(browser.revision)") { entries = await services.playlists.entries(of: id) }
    }

    private func list(_ entries: [PlaylistEntry], _ playlist: Playlist?, editable: Bool) -> some View {
        List {
            PlaylistEntryRows(
                playlistId: id, entries: entries, editable: editable, changed: { self.entries = $0 },
                play: { entry in if let playlist { play(playlist, from: entry, shuffled: false) } })
        }
        .listStyle(.plain).scrollContentBackground(.hidden)
        .pulling {
            async let playlists: Void = services.playlists.load()
            self.entries = await services.playlists.entries(of: id) ?? self.entries
            await playlists
        }
    }

    /// From the top, or from where an entry's rows begin in the play order.
    private func play(_ playlist: Playlist, from entry: PlaylistEntry?, shuffled: Bool) {
        Task {
            guard let rows = await services.playlists.playOrder(of: id) else { return }
            guard let start = entry.map({ rows.start(of: $0.id) }) ?? 0 else { return }
            if playlist.kind == .music {
                await services.player.play(
                    rows.songs, from: start, source: playlist.name, playlistId: id, shuffled: shuffled)
            } else if let queue = VideoQueue(rows, start: start, playlistId: id) {
                browser.play(queue)
            }
        }
    }
}

/// A playlist's entries as list rows; a station's contents are these rows
/// of its playlist.
struct PlaylistEntryRows: View {
    @Environment(Services.self) private var services
    @Environment(CatalogModel.self) private var catalog
    let playlistId: UID
    let entries: [PlaylistEntry]
    var editable = true
    /// Takes the entries read again after an edit.
    let changed: ([PlaylistEntry]?) -> Void
    /// Plays from a tapped entry; nil for a station's, which plays only on the air.
    var play: ((PlaylistEntry) -> Void)?

    var body: some View {
        var moving: ((IndexSet, Int) -> Void)?
        var removing: ((IndexSet) -> Void)?
        if editable {
            moving = { move($0, $1) }
            removing = { remove($0) }
        }
        return ForEach(entries, id: \.id) { entry in
            Group {
                if let play {
                    Button {
                        play(entry)
                    } label: {
                        row(entry)
                    }.buttonStyle(.plain)
                } else {
                    row(entry)
                }
            }
            .contextMenu {
                if let item = entry.item { ItemContextMenu(item: item, play: play.map { play in { play(entry) } }) }
            }
            .listRowBackground(Color.clear)
        }
        .onMove(perform: moving)
        .onDelete(perform: removing)
    }

    private func remove(_ offsets: IndexSet) {
        let doomed = offsets.map { entries[$0] }
        Task {
            for entry in doomed { await services.playlists.remove(entry) }
            changed(await services.playlists.entries(of: playlistId))
        }
    }

    private func row(_ entry: PlaylistEntry) -> some View {
        let music = entry.song != nil || entry.album != nil || entry.artist != nil
        return HStack(spacing: 12) {
            ArtSquare(
                id: entry.artId, aspect: music ? 1 : 2 / 3, radius: 6, collection: entry.kind == .collection,
                placeholder: entry.kind == .collection ? .collection : .playlist,
                badges: entry.song.map { StatusBadges(id: $0.id) }
            )
            .frame(width: 44)
            .overlay(alignment: .bottom) {
                if play != nil, let progress = catalog.catalog.resumeProgress(entry) { ProgressBar(value: progress) }
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(PlaylistText.title(entry)).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                Text(PlaylistText.detail(entry)).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .contentShape(.rect)
    }

    /// A drop below the old place counts the entry itself, which has left its old place by then.
    private func move(_ source: IndexSet, _ destination: Int) {
        guard let from = source.first else { return }
        let entry = entries[from]
        Task {
            await services.playlists.move(entry, to: destination > from ? destination - 1 : destination)
            changed(await services.playlists.entries(of: playlistId))
        }
    }
}
