import RabbitEarsAPI
import RabbitEarsKit
import SwiftUI

struct GridView: View {
    @Environment(AppModel.self) private var app
    @Environment(CatalogModel.self) private var model
    @Environment(Services.self) private var services
    let kind: ItemKind
    @AppStorage private var filter: GridFilter
    @AppStorage private var sort: GridSort
    @State private var genre: Genre.ID?
    @State private var view = GridTab.titles
    @State private var listCount = ""
    @State private var selection = Selection()
    @State private var reloader = Reloader()

    init(kind: ItemKind) {
        self.kind = kind
        _filter = AppStorage(wrappedValue: .all, "grid.\(kind.rawValue).filter")
        _sort = AppStorage(wrappedValue: .recentlyAdded, "grid.\(kind.rawValue).sort")
    }

    static let columns = Array(repeating: GridItem(.flexible(), spacing: 10, alignment: .top), count: 3)

    var body: some View {
        let items = model.catalog.grid(kind, filter: shown, sort: sort, genre: genre, favorites: app.favorites.ids)
        let total = model.catalog.total(kind, filter: shown)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ViewTabs(
                    options: GridTab.tabs(kind, playlists: services.playlists.offersView(PlaylistKind(holding: kind))),
                    title: { $0.title(kind) },
                    selection: $view)
                switch view {
                case .playlists: PlaylistsList(kind: PlaylistKind(holding: kind), count: $listCount)
                case .collections: CollectionsGrid(count: $listCount)
                case .stations: StationsList(kind: PlaylistKind(holding: kind), count: $listCount)
                case .titles:
                    ChipBar(
                        options: filters, title: \.rawValue,
                        selection: Binding(get: { shown }, set: { filter = $0 }))
                    if items.isEmpty {
                        Text(kind == .movie ? "No movies match." : "No shows match.").foregroundStyle(Theme.secondary)
                            .frame(maxWidth: .infinity).padding(40)
                    }
                    LazyVGrid(columns: Self.columns, spacing: 14) {
                        ForEach(items) { Tile(item: $0).selectable($0.id) }
                    }
                }
            }
            .padding(EdgeInsets(top: 0, leading: 20, bottom: 20, trailing: 20))
        }
        .environment(reloader)
        .pulling { await reload() }
        .selecting(selection, view == .titles ? (kind == .movie ? .movie : .show) : nil)
        .onAppear {
            // Every title matching the filter and genre, not only those scrolled in.
            selection.source = .init {
                model.catalog.grid(kind, filter: shown, sort: sort, genre: genre, favorites: app.favorites.ids)
                    .map(\.id)
            }
        }
        .countedTitle(
            (kind == .movie ? LibraryTab.movies : .tv).rawValue, count: view == .titles ? total.formatted() : listCount
        )
        .toolbar {
            if view == .titles {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Sort", selection: $sort) {
                            ForEach(GridSort.allCases, id: \.self) { Text($0.rawValue) }
                        }
                        let genres = model.catalog.genres(kind)
                        if !genres.isEmpty {
                            Picker("Genre", selection: $genre) {
                                Text("All genres").tag(Genre.ID?.none)
                                ForEach(genres) { Text($0.name).tag(Optional($0.id)) }
                            }
                        }
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease")
                    }
                    .accessibilityLabel("Sort and filter")
                }
            }
            BrowseToolbar()
        }
    }

    private func reload() async {
        switch view {
        case .titles: await model.load()
        case .collections: await services.collections.load()
        case .playlists: await services.playlists.load()
        case .stations: await reloader.action?()
        }
    }

    /// The stored pick is per device, so a chip this profile lacks, such as an adult's Kids, reads as All.
    private var shown: GridFilter { filters.contains(filter) ? filter : .all }

    private var filters: [GridFilter] {
        GridFilter.allCases.filter { $0 != .kids || app.activeProfile?.kind == .adult }
    }
}

struct ChipBar<Option: Hashable>: View {
    let options: [Option]
    let title: (Option) -> String
    @Binding var selection: Option

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(options, id: \.self) { option in
                    let selected = option == selection
                    Button(title(option)) { selection = option }
                        .font(.system(size: 14, weight: selected ? .semibold : .medium))
                        .foregroundStyle(selected ? Theme.ground : Theme.primary)
                        .padding(.horizontal, 14).frame(height: 34)
                        .background(selected ? Theme.amber : .clear, in: .capsule)
                        .overlay(Capsule().stroke(selected ? .clear : .white.opacity(0.16)))
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
        }
        .contentMargins(.horizontal, 20, for: .scrollContent)
        .padding(.horizontal, -20)
    }
}
