import RabbitEarsAPI
import RabbitEarsKit
import SwiftUI

/// Movies' Collections view: every collection the profile may see as a
/// poster tile, and for an adult a way to make a custom one.
struct CollectionsGrid: View {
    @Environment(Services.self) private var services
    @Environment(AppModel.self) private var app
    @Environment(Browser.self) private var browser
    @Binding var count: String
    @State private var naming = false
    @State private var name = ""

    var body: some View {
        let model = services.collections
        VStack(alignment: .leading, spacing: 14) {
            if app.activeProfile?.kind == .adult {
                Button {
                    naming = true
                } label: {
                    Label("New collection", systemImage: "plus").font(.system(size: 15, weight: .semibold))
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
                }
                .buttonStyle(.plain).foregroundStyle(Theme.amber)
                Button {
                    browser.smartRules = SmartRulesRequest(target: .newCollection)
                } label: {
                    Label("New smart collection", systemImage: "sparkles").font(.system(size: 15, weight: .semibold))
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
                }
                .buttonStyle(.plain).foregroundStyle(Theme.amber)
                .needsServer(.smartRules)
            }
            if model.collections.isEmpty { EmptyNote(text: "No collections yet.") }
            LazyVGrid(columns: GridView.columns, spacing: 14) {
                ForEach(model.collections) { collection in
                    Button {
                        browser.open(.collection(collection.id))
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            ArtSquare(
                                id: collection.id, aspect: 2 / 3, collection: true, placeholder: .collection,
                                badges: StatusBadges(
                                    id: collection.id, scope: .collection, handOrdered: collection.isHandOrdered))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(collection.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                                Text(collection.summary).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            }
            if let error = model.error { Text(error).font(.system(size: 13)).foregroundStyle(Theme.error) }
        }
        .task { await model.load() }
        .onAppear { count = model.collections.count.formatted() }
        .onChange(of: model.collections.count) { count = model.collections.count.formatted() }
        .alert("New collection", isPresented: $naming) {
            TextField("Name", text: $name)
            Button("Cancel", role: .cancel) { name = "" }
            Button("Create") {
                let chosen = name
                name = ""
                Task { _ = await model.create(name: chosen) }
            }
        }
    }
}

/// One collection: its art, name and overview, then its movies in the
/// server's order. Adults edit a custom one, and put its movies in their own
/// order; a TMDB one is read-only and in release order.
struct CollectionView: View {
    @Environment(Services.self) private var services
    @Environment(CatalogModel.self) private var catalog
    @Environment(AppModel.self) private var app
    @Environment(Browser.self) private var browser
    @Environment(\.dismiss) private var dismiss
    let id: UID
    @State private var movies: [Item]?
    @State private var addTarget: PlaylistTarget?
    @State private var renaming = false
    @State private var deleting = false
    @State private var ordering = false
    @State private var name = ""

    var body: some View {
        let collection = services.collections.collections.first { $0.id == id }
        let adult = app.activeProfile?.kind == .adult
        let custom = adult && collection?.source == .custom
        // A smart one's movies follow its rules; it is still renamed and deleted.
        let editable = custom && collection?.smart != true
        Group {
            if ordering, editable, let collection, let movies {
                orderList(collection, movies)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        if let collection { header(collection) }
                        ShuffleButton(items: movies ?? [])
                        if let movies {
                            if movies.isEmpty { EmptyNote(text: "No movies in this collection yet.") }
                            LazyVGrid(columns: GridView.columns, spacing: 14) {
                                ForEach(movies) { movie in
                                    Tile(
                                        item: catalog.catalog.item(movie.id) ?? movie,
                                        remove: editable ? { remove(movie) } : nil)
                                }
                            }
                        } else {
                            ProgressView().frame(maxWidth: .infinity).padding(40)
                        }
                        if let error = services.collections.error {
                            Text(error).font(.system(size: 13)).foregroundStyle(Theme.error)
                        }
                    }
                    .padding(EdgeInsets(top: 4, leading: 16, bottom: 20, trailing: 16))
                }
                .pulling {
                    async let list: Void = services.collections.load()
                    // The movies the server could not answer stay as shown.
                    movies = await services.collections.movies(of: id) ?? movies
                    await list
                }
            }
        }
        .background(Theme.ground)
        .navigationTitle(collection?.name ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if ordering {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { ordering = false }.fontWeight(.semibold) }
            }
            if adult, let collection { more(collection, custom: custom, editable: editable) }
        }
        .addToPlaylist($addTarget)
        .alert("Rename collection", isPresented: $renaming) {
            TextField("Name", text: $name)
            Button("Cancel", role: .cancel) {}
            Button("Rename") {
                if let collection { Task { await services.collections.rename(collection, to: name) } }
            }
        }
        .confirmationDialog("Delete this collection?", isPresented: $deleting, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let collection { Task { await services.collections.delete(collection) } }
                dismiss()
            }
        } message: {
            Text("Its movies stay in your library.")
        }
        .task(id: id) { movies = await services.collections.movies(of: id) }
    }

    private func header(_ collection: MovieCollection) -> some View {
        VStack(spacing: 14) {
            ArtSquare(
                id: collection.id, aspect: 2 / 3, radius: 10, collection: true, placeholder: .collection,
                badges: StatusBadges(id: collection.id, scope: .collection, handOrdered: collection.isHandOrdered)
            )
            .frame(width: 120)
            VStack(spacing: 6) {
                Text(collection.name).font(.system(size: 26, weight: .bold)).multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                if collection.smart == true { SmartBadge() }
                Text(collection.summary).font(.system(size: 13)).foregroundStyle(Theme.secondary)
            }
            if let overview = collection.overview {
                Text(overview).font(.system(size: 14)).foregroundStyle(Theme.synopsis)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func more(_ collection: MovieCollection, custom: Bool, editable: Bool) -> some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                AddToButtons(target: $addTarget, itemIds: [], kind: .movies, collectionId: collection.id)
                DownloadMenu(.collection(collection))
                if custom && collection.smart == true {
                    Button("Edit rules", systemImage: "sparkles") {
                        browser.smartRules = SmartRulesRequest(target: .collection(collection))
                    }
                    .needsServer(.smartRules)
                }
                if editable {
                    Button("Edit order", systemImage: "arrow.up.arrow.down") { ordering = true }
                        .disabled((movies?.count ?? 0) < 2)
                    if collection.isHandOrdered {
                        Button("Reset to release order", systemImage: "arrow.counterclockwise") { reset() }
                    }
                }
                if custom {
                    Button("Rename", systemImage: "pencil") {
                        name = collection.name
                        renaming = true
                    }
                    Button("Delete collection", systemImage: "trash", role: .destructive) { deleting = true }
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .accessibilityLabel("More")
        }
    }

    /// Every movie in a row with its place and the system's drag handle, which VoiceOver moves too.
    private func orderList(_ collection: MovieCollection, _ movies: [Item]) -> some View {
        List {
            header(collection).listRowBackground(Color.clear).listRowSeparator(.hidden)
            ForEach(Array(movies.enumerated()), id: \.element.id) { index, movie in
                orderRow(index, movie).listRowBackground(Color.clear)
            }
            .onMove { source, destination in move(source, destination, in: movies) }
            Text("Drag a movie to reorder. Everyone who can see this collection sees your order.")
                .font(.system(size: 13)).foregroundStyle(Theme.secondary)
                .listRowBackground(Color.clear).listRowSeparator(.hidden)
            if let error = services.collections.error {
                Text(error).font(.system(size: 13)).foregroundStyle(Theme.error)
                    .listRowBackground(Color.clear).listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain).scrollContentBackground(.hidden)
        .environment(\.editMode, .constant(.active))
    }

    private func orderRow(_ index: Int, _ movie: Item) -> some View {
        HStack(spacing: 12) {
            Text("\(index + 1)").font(.system(size: 15)).foregroundStyle(Theme.secondary).monospacedDigit()
                .frame(minWidth: 22, alignment: .trailing)
            ArtSquare(id: movie.id, aspect: 2 / 3, radius: 4, badged: false).frame(width: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(Catalog.title(movie)).font(.system(size: 15, weight: .medium)).lineLimit(1)
                Text(CollectionsModel.detail(of: movie)).font(.system(size: 13))
                    .foregroundStyle(Theme.secondary).lineLimit(1)
            }
        }
    }

    /// The list shows the drop at once; the server's order, read back, then replaces it. The position is the row's
    /// among the movies this profile sees, so a movie hidden from it shifts the drop in the full order.
    private func move(_ source: IndexSet, _ destination: Int, in shown: [Item]) {
        guard let from = source.first else { return }
        let position = CollectionsModel.position(moving: from, toOffset: destination)
        guard position != from else { return }
        var dropped = shown
        dropped.move(fromOffsets: source, toOffset: destination)
        movies = dropped
        Task { movies = await services.collections.reorder(shown[from].id, in: id, to: position) ?? shown }
    }

    private func reset() {
        Task { movies = await services.collections.restoreReleaseOrder(of: id) ?? movies }
    }

    private func remove(_ movie: Item) {
        Task {
            await services.collections.remove(movie: movie.id, from: id)
            movies = await services.collections.movies(of: id)
        }
    }
}

/// Add to collection on a movie: the household's custom collections, then a new one.
struct AddToCollectionSheet: View {
    @Environment(Services.self) private var services
    @Environment(\.dismiss) private var dismiss
    let movieId: UID
    @State private var naming = false
    @State private var name = ""

    var body: some View {
        let collections = services.collections
        NavigationStack {
            List {
                Button("New collection", systemImage: "plus") { naming = true }
                ForEach(collections.custom) { collection in
                    Button {
                        Task { await add(to: collection) }
                    } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(collection.name).font(.system(size: 15, weight: .semibold))
                            Text(collection.summary).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                        }
                    }
                }
                if let error = collections.error {
                    Text(error).foregroundStyle(Theme.error).font(.system(size: 13))
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.raised)
            .navigationTitle("Add to collection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .alert("New collection", isPresented: $naming) {
                TextField("Name", text: $name)
                Button("Cancel", role: .cancel) { name = "" }
                Button("Create") {
                    let chosen = name
                    name = ""
                    Task {
                        if let collection = await collections.create(name: chosen) { await add(to: collection) }
                    }
                }
            }
        }
        .foregroundStyle(Theme.primary)
    }

    private func add(to collection: MovieCollection) async {
        if await services.collections.add(movie: movieId, to: collection.id) { dismiss() }
    }
}

struct CollectionLinks: View {
    @Environment(Browser.self) private var browser
    let collections: [MovieCollection]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(collections.count == 1 ? "Collection" : "Collections").font(.system(size: 12))
                .foregroundStyle(Theme.secondary)
            ForEach(collections) { collection in
                Button(collection.name) { browser.open(.collection(collection.id)) }
                    .buttonStyle(.plain).font(.system(size: 15)).foregroundStyle(Theme.amber)
            }
        }
    }
}

/// Shuffle on a collection; absent when none of its movies has a file.
private struct ShuffleButton: View {
    @Environment(AppModel.self) private var app
    @Environment(CatalogModel.self) private var catalog
    @Environment(Browser.self) private var browser
    let items: [Item]

    var body: some View {
        if items.contains(where: VideoQueue.shuffles) {
            Button {
                browser.shuffle(items, downloads: app.downloads, profile: catalog.profileId)
            } label: {
                Label("Shuffle", systemImage: "shuffle").frame(maxWidth: .infinity)
            }
            .buttonStyle(SecondaryButtonStyle(fullWidth: true))
        }
    }
}
