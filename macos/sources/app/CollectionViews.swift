import RabbitEarsAPI
import RabbitEarsKit
import SwiftUI

/// A request to name a custom collection: new, perhaps for a movie to
/// land in, or renaming one. Shown as a sheet over the whole window.
struct CollectionNameRequest: Identifiable {
    let id = UUID()
    var movieId: UID?
    var renaming: MovieCollection?
}

struct CollectionNameSheet: View {
    @Environment(CollectionsModel.self) private var collections
    @Environment(Browser.self) private var browser
    @Environment(\.dismiss) private var dismiss
    let request: CollectionNameRequest
    @State private var name = ""
    @State private var smart = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(request.renaming == nil ? "New collection" : "Rename collection")
                .font(.system(size: 17, weight: .bold))
            LabeledField(label: "Name", error: collections.error) {
                TextField("Name", text: $name).onSubmit(save)
            }
            if request.offersSmart { SmartToggle(isOn: $smart) }
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
        if let rules = request.smartRules(named: name, smart: smart) {
            browser.smartNext = rules
            dismiss()
            return
        }
        Task {
            if let renaming = request.renaming {
                await collections.rename(renaming, to: name)
            } else {
                let made = await collections.create(name: name)
                guard let made else { return }
                if let movieId = request.movieId { await collections.add(movie: movieId, to: made.id) }
            }
            if collections.error == nil { dismiss() }
        }
    }
}

/// Add to collection in a movie's More menu: the household's custom
/// collections, then a new one. Nothing for a kid.
struct CollectionMenu: View {
    @Environment(CollectionsModel.self) private var collections: CollectionsModel?
    @Environment(AppModel.self) private var app
    @Environment(Browser.self) private var browser
    let movieId: UID

    var body: some View {
        if let collections, app.isAdult {
            Menu("Add to collection") {
                ForEach(collections.custom) { collection in
                    Button(collection.name) { Task { await collections.add(movie: movieId, to: collection.id) } }
                }
                if !collections.custom.isEmpty { Divider() }
                Button("New collection…") { browser.namingCollection = CollectionNameRequest(movieId: movieId) }
            }
        }
    }
}

/// The collections a movie's details name, each opening its page.
struct InCollections: View {
    @Environment(CollectionsModel.self) private var collections: CollectionsModel?
    @Environment(Browser.self) private var browser
    let movieId: UID
    @State private var named: [MovieCollection] = []

    var body: some View {
        Flow {
            ForEach(named) { collection in
                Button(collection.name) { browser.open(.collection(collection.id)) }
                    .buttonStyle(.plain).font(.system(size: 13)).foregroundStyle(Theme.secondary)
            }
        }
        // Any write to a collection may change which ones name this movie.
        .task(id: collections?.collections) { named = await collections?.collections(of: movieId) ?? [] }
    }
}

/// Movies' Collections view: New collection for an adult, then every
/// collection the profile may see.
struct CollectionGrid: View {
    @Environment(CollectionsModel.self) private var collections
    @Environment(AppModel.self) private var app
    @Environment(Browser.self) private var browser

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if app.isAdult {
                Button {
                    browser.namingCollection = CollectionNameRequest()
                } label: {
                    Label("New collection", systemImage: "plus")
                }
                .buttonStyle(SecondaryButtonStyle())
            }
            if collections.collections.isEmpty {
                Text("No collections yet.").foregroundStyle(Theme.secondary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 123), spacing: 14, alignment: .top)], spacing: 16) {
                ForEach(collections.collections) { CollectionTile(collection: $0) }
            }
        }
        .task { await collections.load() }
    }
}

struct CollectionTile: View {
    @Environment(Browser.self) private var browser
    let collection: MovieCollection

    var body: some View {
        Button {
            browser.open(.collection(collection.id))
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Art(
                    id: collection.id, aspect: 2 / 3, collection: true, placeholder: .collection,
                    badges: StatusBadges(id: collection.id, scope: .collection, handOrdered: collection.isHandOrdered))
                Text(collection.name).font(.system(size: 12, weight: .semibold)).lineLimit(2)
                Text(collection.summary).font(.system(size: 11)).foregroundStyle(Theme.secondary)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

/// One collection: its movies in the server's order. An adult adds it to a
/// movies playlist, and on a custom one renames, deletes, removes movies and
/// puts them in their own order.
struct CollectionScreen: View {
    @Environment(CollectionsModel.self) private var collections
    @Environment(CatalogModel.self) private var catalog
    @Environment(AppModel.self) private var app
    @Environment(Browser.self) private var browser
    let id: UID
    @State private var movies: [Item]?
    @State private var ordering = false

    var body: some View {
        let collection = collections.collections.first(where: { $0.id == id })
        Group {
            if let collection {
                // A smart one's movies follow its rules; it is still renamed and deleted.
                let editable = app.isAdult && collection.source == .custom && collection.smart != true
                if ordering, editable, let movies {
                    VStack(alignment: .leading, spacing: 18) {
                        header(collection, editable: editable)
                        orderList(movies)
                    }
                    .padding(EdgeInsets(top: 18, leading: 22, bottom: 12, trailing: 22))
                    .pageTitle(collection.name)
                } else {
                    grid(collection, editable: editable)
                }
            } else {
                ContentUnavailableView("Not available", systemImage: "questionmark.square.dashed")
            }
        }
        .task(id: collection) { movies = await collections.movies(of: id) }
    }

    private func grid(_ collection: MovieCollection, editable: Bool) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header(collection, editable: editable)
                if let movies {
                    if movies.isEmpty {
                        Text("No movies in this collection yet.").foregroundStyle(Theme.secondary)
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 14, alignment: .top)], spacing: 16) {
                        ForEach(movies) { movie in
                            Tile(
                                item: catalog.catalog.item(movie.id) ?? movie,
                                remove: editable ? { remove(movie, from: collection) } : nil)
                        }
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
            .padding(EdgeInsets(top: 18, leading: 22, bottom: 24, trailing: 22))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .pageTitle(collection.name)
    }

    /// Every movie in a row with its place; a drag moves it, and so does VoiceOver's list reordering.
    private func orderList(_ movies: [Item]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            List {
                ForEach(Array(movies.enumerated()), id: \.element.id) { index, movie in
                    orderRow(index, movie).listRowBackground(Color.clear).listRowSeparator(.hidden)
                }
                .onMove { source, destination in move(source, destination, in: movies) }
            }
            .listStyle(.plain).scrollContentBackground(.hidden)
            Text(collections.error ?? "Drag a movie to reorder. Everyone who can see this collection sees your order.")
                .font(.system(size: 12)).foregroundStyle(collections.error == nil ? Theme.secondary : Theme.red)
        }
    }

    private func orderRow(_ index: Int, _ movie: Item) -> some View {
        HStack(spacing: 12) {
            Text("\(index + 1)").font(.system(size: 13)).foregroundStyle(Theme.secondary).monospacedDigit()
                .frame(minWidth: 22, alignment: .trailing)
            Art(id: movie.id, aspect: 2 / 3, radius: 4, badged: false).frame(width: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(Catalog.title(movie)).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(CollectionsModel.detail(of: movie)).font(.system(size: 12))
                    .foregroundStyle(Theme.secondary).lineLimit(1)
            }
            Spacer()
            Image(systemName: "line.3.horizontal").foregroundStyle(Theme.secondary).accessibilityHidden(true)
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
        Task { movies = await collections.reorder(shown[from].id, in: id, to: position) ?? shown }
    }

    private func reset() {
        Task { movies = await collections.restoreReleaseOrder(of: id) ?? movies }
    }

    private func header(_ collection: MovieCollection, editable: Bool) -> some View {
        HStack(alignment: .top, spacing: 24) {
            Art(
                id: collection.id, aspect: 2 / 3, radius: 10, collection: true, placeholder: .collection,
                badges: StatusBadges(id: collection.id, scope: .collection, handOrdered: collection.isHandOrdered)
            )
            .frame(width: 150)
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Text(collection.name).font(.system(size: 26, weight: .bold))
                    if collection.smart == true { SmartBadge() }
                }
                Text(collection.summary).font(.system(size: 13)).foregroundStyle(Theme.secondary)
                Flow {
                    ShuffleButton(items: movies ?? [])
                    PlaylistMenu(collectionId: collection.id, kind: .movies, asButton: true)
                    StationMenu(collectionId: collection.id, kind: .movies, asButton: true)
                    DownloadButton(target: .collection(collection))
                    if ordering {
                        Button("Done") { ordering = false }.buttonStyle(PrimaryButtonStyle())
                    }
                    if app.isAdult && collection.source == .custom {
                        Menu {
                            if collection.smart == true {
                                Button("Edit rules…") {
                                    browser.smartRules = SmartRulesRequest(target: .collection(collection))
                                }
                                .needsServer(.smartRules)
                            }
                            if editable {
                                Button("Edit order", systemImage: "arrow.up.arrow.down") { ordering = true }
                                    .disabled((movies?.count ?? 0) < 2)
                            }
                            if editable && collection.isHandOrdered {
                                Button("Reset to release order", systemImage: "arrow.counterclockwise") { reset() }
                            }
                            Button("Rename…") { browser.namingCollection = CollectionNameRequest(renaming: collection) }
                            Button("Delete…", role: .destructive) { browser.deletingCollection = collection }
                        } label: {
                            Image(systemName: "ellipsis")
                        }
                        .menuStyle(.button).menuIndicator(.hidden).buttonStyle(SecondaryButtonStyle()).fixedSize()
                        .accessibilityLabel("More")
                    }
                }
                if let overview = collection.overview {
                    Text(overview).font(.system(size: 13)).foregroundStyle(Theme.synopsis)
                        .frame(maxWidth: 560, alignment: .leading)
                }
            }
        }
    }

    private func remove(_ movie: Item, from collection: MovieCollection) {
        Task { await collections.remove(movie: movie.id, from: collection.id) }
    }
}
