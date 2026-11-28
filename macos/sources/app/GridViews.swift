import RabbitEarsAPI
import RabbitEarsKit
import SwiftUI

struct Chips<Option: Hashable>: View {
    let options: [Option]
    let label: (Option) -> String
    @Binding var selection: Option

    var body: some View {
        ForEach(options, id: \.self) { option in
            Chip(title: label(option), picked: selection == option) { selection = option }
        }
    }
}

struct Chip: View {
    let title: String
    let picked: Bool
    let action: () -> Void

    var body: some View {
        Button(title, action: action)
            .font(.system(size: 12, weight: picked ? .semibold : .medium))
            .foregroundStyle(picked ? Theme.ground : Theme.primary)
            .padding(.horizontal, 12).frame(height: 26)
            .background(picked ? Theme.amber : .clear, in: .capsule)
            .overlay(Capsule().stroke(picked ? .clear : Theme.border))
            .buttonStyle(.plain)
            .accessibilityAddTraits(picked ? .isSelected : [])
    }
}

/// The Downloaded filter, which every library grid shares.
struct DownloadedChip: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        if let downloads = app.downloads {
            Chip(title: "Downloaded", picked: downloads.downloadedOnly) { downloads.downloadedOnly.toggle() }
        }
    }
}

/// A library screen's views; the first label lines up with the content below.
struct ViewTabs<Option: Hashable>: View {
    let options: [Option]
    let label: (Option) -> String
    @Binding var selection: Option

    var body: some View {
        if options.count > 1 {
            HStack(spacing: 2) {
                ForEach(options, id: \.self) { option in
                    ViewTab(title: label(option), current: selection == option) { selection = option }
                }
            }
            .padding(.leading, -10)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("View")
        }
    }
}

private struct ViewTab: View {
    let title: String
    let current: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 13, weight: .medium))
                .foregroundStyle(current || hovered ? .white : Theme.secondary)
                .padding(.vertical, 6).padding(.horizontal, 10)
                .background(current ? Theme.border : .clear, in: .rect(cornerRadius: 6))
                .contentShape(.rect(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityAddTraits(current ? .isSelected : [])
    }
}

struct GridView: View {
    @Environment(AppModel.self) private var app
    @Environment(CatalogModel.self) private var model
    @Environment(PlaylistsModel.self) private var playlists: PlaylistsModel?
    let kind: ItemKind
    @AppStorage private var filter: GridFilter
    @AppStorage private var sort: GridSort
    @State private var genre: Genre.ID?
    @State private var view = GridTab.titles
    @State private var selection = Selection()

    init(kind: ItemKind) {
        self.kind = kind
        _filter = AppStorage(wrappedValue: .all, "grid.\(kind.rawValue).filter")
        _sort = AppStorage(wrappedValue: .recentlyAdded, "grid.\(kind.rawValue).sort")
    }

    var body: some View {
        let items = model.catalog.grid(
            kind, filter: shown, sort: sort, genre: genre, favorites: app.favorites.ids, onDevice: app.downloadedFilter)
        let genres = model.catalog.genres(kind)
        let total = model.catalog.total(kind, filter: shown)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ViewTabs(
                    options: GridTab.tabs(
                        kind, playlists: playlists?.offersView(PlaylistKind(holding: kind)) == true),
                    label: { $0.title(kind) },
                    selection: $view)
                switch view {
                case .titles:
                    HStack(spacing: 8) {
                        Chips(
                            options: filters, label: \.rawValue,
                            selection: Binding(get: { shown }, set: { filter = $0 }))
                        DownloadedChip()
                        Spacer()
                        if !genres.isEmpty {
                            Picker("Genre", selection: $genre) {
                                Text("All genres").tag(Genre.ID?.none)
                                ForEach(genres) { Text($0.name).tag(Optional($0.id)) }
                            }
                            .fixedSize()
                        }
                        Picker("Sort", selection: $sort) {
                            ForEach(GridSort.allCases, id: \.self) { Text($0.rawValue) }
                        }
                        .fixedSize()
                        SelectButton(selection: selection, kind: selectKind)
                    }
                    grid(items)
                case .playlists: PlaylistGrid(kind: PlaylistKind(holding: kind))
                case .collections: CollectionGrid()
                case .stations: StationGrid(kind: PlaylistKind(holding: kind))
                }
            }
            .padding(EdgeInsets(top: 10, leading: 22, bottom: 24, trailing: 22))
        }
        .selectionBar(selection, selectKind, order: items.map(\.id))
        .onChange(of: view) { selection.end() }
        .navigationSubtitle(kind == .movie ? "\(total) movies" : "\(total) shows")
    }

    private var selectKind: SelectKind { kind == .movie ? .movie : .show }

    @ViewBuilder
    private func grid(_ items: [Item]) -> some View {
        if items.isEmpty {
            Text(emptyText).foregroundStyle(Theme.secondary).frame(maxWidth: .infinity).padding(40)
        }
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 14, alignment: .top)], spacing: 16) {
            let order = items.map(\.id)
            ForEach(items) { Tile(item: $0).selectable(selection, $0.id, in: order) }
        }
    }

    private var emptyText: String {
        if app.downloads?.downloadedOnly == true { return "Nothing downloaded here yet." }
        return kind == .movie ? "No movies match." : "No shows match."
    }

    /// The stored pick is per device, so a chip this profile lacks, such as an adult's Kids, reads as All.
    private var shown: GridFilter { filters.contains(filter) ? filter : .all }

    private var filters: [GridFilter] {
        GridFilter.allCases.filter { $0 != .kids || app.activeProfile?.kind == .adult }
    }
}
