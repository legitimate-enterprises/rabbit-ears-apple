import RabbitEarsAPI
import RabbitEarsKit
import SwiftUI

/// A new playlist, perhaps for an item or collection to land in, or a rename.
struct PlaylistNameRequest: Identifiable {
    let id = UUID()
    var kind = PlaylistKind.music
    var itemId: UID?
    /// The edition chosen on details; nil asks the server, which may ask the adult.
    var editionId: UID?
    var collectionId: UID?
    /// A library selection to add, in place of itemId.
    var itemIds: [UID] = []
    var renaming: Playlist?
}

struct PlaylistNameSheet: View {
    @Environment(PlaylistsModel.self) private var playlists
    @Environment(\.dismiss) private var dismiss
    let request: PlaylistNameRequest
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(request.renaming == nil ? "New playlist" : "Rename playlist").font(.system(size: 17, weight: .bold))
            LabeledField(label: "Name", error: playlists.error) {
                TextField("Name", text: $name).onSubmit(save)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(SecondaryButtonStyle())
                Button(request.renaming == nil ? "Create" : "Save", action: save).buttonStyle(PrimaryButtonStyle())
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24).frame(width: 380)
        .background(Theme.card)
        .onAppear { name = request.renaming?.name ?? "" }
    }

    private func save() {
        Task {
            if let renaming = request.renaming {
                await playlists.rename(renaming, to: name)
            } else {
                guard let made = await playlists.create(name: name, kind: request.kind) else { return }
                if request.itemIds.isEmpty {
                    await playlists.add(
                        item: request.itemId, edition: request.editionId, collection: request.collectionId, to: made.id)
                } else {
                    await playlists.add(request.itemIds, to: made.id)
                }
            }
            if playlists.error == nil { dismiss() }
        }
    }
}

/// Nothing for a kid, who only reads.
struct PlaylistMenu: View {
    @Environment(PlaylistsModel.self) private var playlists: PlaylistsModel?
    @Environment(Browser.self) private var browser
    var itemId: UID?
    /// The edition chosen on details, added without another question.
    var editionId: UID?
    var collectionId: UID?
    let kind: PlaylistKind
    /// A bordered button beside Play on a details page; a plain menu item elsewhere.
    var asButton = false

    var body: some View {
        if let playlists, playlists.adult {
            let lists = playlists.editable(kind)
            if asButton {
                Menu {
                    choices(lists, playlists)
                } label: {
                    Text("Add to playlist")
                }
                .menuStyle(.button).menuIndicator(.hidden).buttonStyle(SecondaryButtonStyle()).fixedSize()
            } else {
                Menu("Add to playlist") { choices(lists, playlists) }
                StationMenu(itemId: itemId, editionId: editionId, collectionId: collectionId, kind: kind)
            }
        }
    }

    @ViewBuilder
    private func choices(_ lists: [Playlist], _ playlists: PlaylistsModel) -> some View {
        ForEach(lists, id: \.id) { list in
            Button(list.name) {
                Task { await playlists.add(item: itemId, edition: editionId, collection: collectionId, to: list.id) }
            }
        }
        if !lists.isEmpty { Divider() }
        Button("New playlist…") {
            browser.naming = PlaylistNameRequest(
                kind: kind, itemId: itemId, editionId: editionId, collectionId: collectionId)
        }
    }
}

extension PlaylistsModel {
    /// Adds the item, or else the collection as one entry, to a playlist or a station's own.
    /// Whether it went in; a title of several editions without one chosen stops for the question.
    @discardableResult
    func add(item: UID?, edition: UID?, collection: UID?, to playlistId: UID) async -> Bool {
        if let collection { return await add(collection: collection, to: playlistId) }
        if let item { return await add(item, to: playlistId, edition: edition) }
        return false
    }
}

extension View {
    /// Asks which edition when an add of a title of several came without one.
    func editionQuestion(_ playlists: PlaylistsModel?) -> some View {
        confirmationDialog(
            "Which edition?",
            isPresented: Binding(
                get: { playlists?.editionQuestion != nil }, set: { if !$0 { playlists?.editionQuestion = nil } }),
            titleVisibility: .visible, presenting: playlists?.editionQuestion
        ) { question in
            ForEach(question.editions, id: \.id) { edition in
                Button(Editions.label(edition)) { Task { await playlists?.answer(question, with: edition) } }
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}

struct PlaylistActions: View {
    @Environment(Browser.self) private var browser
    @Environment(PlaylistsModel.self) private var playlists: PlaylistsModel?
    let playlist: Playlist

    var body: some View {
        DownloadMenu(.playlist(playlist))
        if playlist.isOwned {
            Button("Share…") { browser.sharing = playlist }
            Button("Rename…") { browser.naming = PlaylistNameRequest(renaming: playlist) }
            if let playlists { imageActions(playlists) }
            Button("Delete…", role: .destructive) { browser.deleting = playlist }
        }
    }

    @ViewBuilder private func imageActions(_ playlists: PlaylistsModel) -> some View {
        Button("Set image…") { browser.imaging = ImageRequest(playlist: playlist, profileId: playlists.profileId) }
        if playlist.imageUrl != nil {
            Button("Remove image") {
                let target = ImageTarget.playlist(profileId: playlists.profileId, playlistId: playlist.id)
                Task {
                    if await CustomImageModel(client: playlists.client).remove(from: target) { await playlists.load() }
                }
            }
        }
    }
}

struct PlaylistGrid: View {
    @Environment(PlaylistsModel.self) private var playlists
    @Environment(Browser.self) private var browser
    let kind: PlaylistKind

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if playlists.adult {
                Button {
                    browser.naming = PlaylistNameRequest(kind: kind)
                } label: {
                    Label("New playlist", systemImage: "plus")
                }
                .buttonStyle(SecondaryButtonStyle())
            }
            let lists = playlists.playlists(kind)
            if lists.isEmpty { Text("No playlists yet.").foregroundStyle(Theme.secondary) }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 123), spacing: 14, alignment: .top)], spacing: 16) {
                ForEach(lists, id: \.id) { PlaylistTile(playlist: $0) }
            }
        }
        .task { await playlists.load() }
    }
}

struct PlaylistTile: View {
    @Environment(Browser.self) private var browser
    let playlist: Playlist

    var body: some View {
        Button {
            browser.open(.playlist(playlist.id))
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Art(
                    id: playlist.artItemId ?? playlist.id, aspect: playlist.kind == .music ? 1 : 2 / 3,
                    url: playlist.imageUrl, placeholder: .playlist,
                    badges: StatusBadges(id: playlist.id, scope: .playlist, shared: playlist.isShared))
                Text(playlist.name).font(.system(size: 12, weight: .semibold)).lineLimit(2)
                Text(PlaylistText.summary(playlist)).font(.system(size: 11)).foregroundStyle(Theme.secondary)
                if let shared = playlist.sharedBy {
                    Text(shared).font(.system(size: 11)).foregroundStyle(Theme.secondary).lineLimit(1)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .contextMenu { PlaylistActions(playlist: playlist) }
    }
}

/// Play walks the server's play order, music in the music player and movies
/// and episodes in the video player.
struct PlaylistScreen: View {
    @Environment(PlaylistsModel.self) private var playlists
    @Environment(MusicPlayer.self) private var player: MusicPlayer?
    @Environment(Browser.self) private var browser
    let id: UID
    @State private var entries: [PlaylistEntry]?

    var body: some View {
        if let playlist = playlists.playlists.first(where: { $0.id == id }) {
            VStack(alignment: .leading, spacing: 18) {
                header(playlist)
                if let entries {
                    if entries.isEmpty {
                        Text("Nothing in this playlist yet.").foregroundStyle(Theme.secondary)
                    } else {
                        list(playlist, entries)
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
                Spacer(minLength: 0)
            }
            .padding(EdgeInsets(top: 18, leading: 22, bottom: 12, trailing: 22))
            .pageTitle(playlist.name)
            .task(id: "\(id)/\(browser.revision)") { entries = await playlists.entries(of: id) }
        } else {
            ContentUnavailableView("Not available", systemImage: "questionmark.square.dashed")
        }
    }

    private func header(_ playlist: Playlist) -> some View {
        HStack(alignment: .top, spacing: 24) {
            Art(
                id: playlist.artItemId ?? playlist.id, aspect: playlist.kind == .music ? 1 : 2 / 3, radius: 10,
                url: playlist.imageUrl, placeholder: .playlist,
                badges: StatusBadges(id: playlist.id, scope: .playlist, shared: playlist.isShared)
            )
            .frame(width: 150)
            VStack(alignment: .leading, spacing: 12) {
                Text(playlist.name).font(.system(size: 26, weight: .bold))
                Text(PlaylistText.summary(playlist)).font(.system(size: 13)).foregroundStyle(Theme.secondary)
                if let shared = playlist.sharedBy {
                    Text(shared).font(.system(size: 13)).foregroundStyle(Theme.secondary)
                }
                HStack(spacing: 10) {
                    Button {
                        start(playlist, from: nil, shuffled: false)
                    } label: {
                        Label("Play", systemImage: "play.fill")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    if playlist.kind == .music {
                        Button {
                            start(playlist, from: nil, shuffled: true)
                        } label: {
                            Label("Shuffle", systemImage: "shuffle")
                        }
                        .buttonStyle(SecondaryButtonStyle())
                    }
                    Menu {
                        PlaylistActions(playlist: playlist)
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .menuStyle(.button).menuIndicator(.hidden).buttonStyle(SecondaryButtonStyle()).fixedSize()
                    .accessibilityLabel("More")
                }
            }
        }
    }

    private func list(_ playlist: Playlist, _ entries: [PlaylistEntry]) -> some View {
        PlaylistEntryList(
            playlistId: id, entries: Binding(get: { entries }, set: { self.entries = $0 }),
            editable: playlists.adult && playlist.isEditable
        ) { entry in
            start(playlist, from: entry, shuffled: false)
        }
    }

    /// From the top, or from where an entry's rows begin in the play order.
    private func start(_ playlist: Playlist, from entry: PlaylistEntry?, shuffled: Bool) {
        Task {
            guard let rows = await playlists.playOrder(of: id) else { return }
            guard let start = entry.map({ rows.start(of: $0.id) }) ?? 0 else { return }
            if playlist.kind == .music {
                await player?.play(rows.songs, from: start, source: playlist.name, playlistId: id, shuffled: shuffled)
            } else if let queue = VideoQueue(rows, start: start, playlistId: id) {
                browser.play(queue)
            }
        }
    }
}

/// A playlist's or a station's entries in order, with reorder and remove
/// when editable; a show, album or collection is one row.
struct PlaylistEntryList: View {
    @Environment(PlaylistsModel.self) private var playlists
    let playlistId: UID
    @Binding var entries: [PlaylistEntry]
    var editable = true
    /// What a row's tap plays; a station's rows play nothing.
    var play: ((PlaylistEntry) -> Void)?

    var body: some View {
        List {
            ForEach(entries, id: \.id) { entry in
                row(entry)
                    .contentShape(.rect)
                    .onTapGesture { play?(entry) }
                    .contextMenu {
                        if let item = entry.item {
                            ItemContextMenu(item: item, play: play.map { play in { play(entry) } })
                        }
                        if editable { Button("Remove") { remove(entry) } }
                    }
                    .listRowBackground(Color.clear).listRowSeparator(.hidden)
            }
            .onMove(perform: editable ? { offsets, destination in move(offsets, destination) } : nil)
        }
        .listStyle(.plain).scrollContentBackground(.hidden)
    }

    private func row(_ entry: PlaylistEntry) -> some View {
        let music = entry.song != nil || entry.album != nil || entry.artist != nil
        return HStack(spacing: 12) {
            Art(
                id: entry.artId, aspect: music ? 1 : 2 / 3, radius: 4, collection: entry.kind == .collection,
                placeholder: entry.kind == .collection ? .collection : .playlist,
                badges: entry.song.map { StatusBadges(id: $0.id) }
            )
            .frame(width: 36)
            VStack(alignment: .leading, spacing: 1) {
                Text(PlaylistText.title(entry)).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(PlaylistText.detail(entry)).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if entry.kind == .song || entry.kind == .episode {
                Text(Format.clock(seconds: Double(entry.durationMs) / 1000)).monospacedDigit()
                    .font(.system(size: 13)).foregroundStyle(Theme.secondary)
            }
        }
    }

    private func remove(_ entry: PlaylistEntry) {
        Task {
            await playlists.remove(entry)
            if let fresh = await playlists.entries(of: playlistId) { entries = fresh }
        }
    }

    /// The list shows the new order at once; the server then renumbers.
    private func move(_ offsets: IndexSet, _ destination: Int) {
        guard let from = offsets.first else { return }
        let current = entries
        var reordered = current
        reordered.move(fromOffsets: offsets, toOffset: destination)
        entries = reordered
        let entry = current[from]
        Task {
            await playlists.move(entry, to: reordered.firstIndex { $0.id == entry.id } ?? from)
            if let fresh = await playlists.entries(of: playlistId) { entries = fresh }
        }
    }
}
