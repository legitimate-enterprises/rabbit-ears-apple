import RabbitEarsAPI
import RabbitEarsKit
import SwiftUI

/// The views a library screen switches between, 24pt above the row below.
struct ViewTabs<Option: Hashable>: View {
    let options: [Option]
    let label: (Option) -> String
    @Binding var selection: Option

    var body: some View {
        if options.count > 1 {
            HStack(spacing: 4) {
                ForEach(options, id: \.self) { option in
                    let current = selection == option
                    Button(label(option)) { selection = option }
                        .buttonStyle(TabButtonStyle(current: current))
                        .accessibilityAddTraits(current ? .isSelected : [])
                }
            }
            // Full width, so Up from anywhere in the row below lands here before the top bar.
            .frame(maxWidth: .infinity, alignment: .leading)
            .focusSection()
            .accessibilityElement(children: .contain)
            .accessibilityLabel("View")
            .padding(.bottom, -20)
        }
    }
}

struct GridView: View {
    @Environment(AppModel.self) private var app
    @Environment(CatalogModel.self) private var model
    @Environment(PlaylistsModel.self) private var playlists
    @Environment(CollectionsModel.self) private var collections
    let kind: ItemKind
    @AppStorage private var filter: GridFilter
    @AppStorage private var sort: GridSort
    @State private var genre: Genre.ID?
    @State private var view = GridTab.titles
    @State private var stations: [Station]?

    init(kind: ItemKind) {
        self.kind = kind
        _filter = AppStorage(wrappedValue: .all, "grid.\(kind.rawValue).filter")
        _sort = AppStorage(wrappedValue: .recentlyAdded, "grid.\(kind.rawValue).sort")
    }

    static let columns = Array(repeating: GridItem(.fixed(260), spacing: 40, alignment: .top), count: 6)

    var body: some View {
        let catalog = model.catalog
        let items = catalog.grid(kind, filter: shown, sort: sort, genre: genre)
        let total = catalog.total(kind, filter: shown)
        let genres = catalog.genres(kind)
        ScrollView {
            VStack(alignment: .leading, spacing: 44) {
                ViewTabs(
                    options: GridTab.tabs(kind, playlists: playlists.offersView(PlaylistKind(holding: kind))),
                    label: { $0.title(kind) },
                    selection: $view)
                HStack(spacing: 16) {
                    if view == .titles {
                        ForEach(filters, id: \.self) { option in
                            Button(option.rawValue) { filter = option }
                                .buttonStyle(ChipStyle(selected: shown == option))
                        }
                    }
                    Text(caption(total)).font(.system(size: 30)).foregroundStyle(Theme.secondary)
                        .padding(.leading, view == .titles ? 16 : 0)
                    Spacer()
                    if view == .titles { menus(genres) }
                }
                .buttonStyle(ChipStyle(selected: false, radius: 12))
                .focusSection()
                switch view {
                case .playlists: PlaylistTiles(kind: PlaylistKind(holding: kind))
                case .collections: CollectionTiles()
                case .stations: StationTiles(kind: PlaylistKind(holding: kind), list: $stations)
                case .titles: grid(items)
                }
            }
            .padding(EdgeInsets(top: shellTop + 8, leading: 80, bottom: 60, trailing: 80))
        }
        .scrollClipDisabled()
    }

    private func caption(_ total: Int) -> String {
        switch view {
        case .titles: return "\(total.formatted()) \(kind == .movie ? "movies" : "shows")"
        case .playlists:
            let count = playlists.playlists(PlaylistKind(holding: kind)).count
            return Format.count(count, "playlist")
        case .collections:
            let count = collections.collections.count
            return Format.count(count, "collection")
        case .stations: return StationTiles.count(stations)
        }
    }

    @ViewBuilder
    private func menus(_ genres: [Genre]) -> some View {
        Menu {
            Picker("Sort", selection: $sort) {
                ForEach(GridSort.allCases, id: \.self) { Text($0.rawValue) }
            }
        } label: {
            MenuLabel(key: "Sort", value: sort.rawValue)
        }
        if !genres.isEmpty {
            Menu {
                Picker("Genre", selection: $genre) {
                    Text("Any").tag(Genre.ID?.none)
                    ForEach(genres) { Text($0.name).tag(Optional($0.id)) }
                }
            } label: {
                MenuLabel(key: "Genre", value: genres.first { $0.id == genre }?.name ?? "Any")
            }
        }
    }

    @ViewBuilder
    private func grid(_ items: [Item]) -> some View {
        if items.isEmpty {
            Text(kind == .movie ? "No movies match." : "No shows match.").font(.system(size: 30))
                .foregroundStyle(Theme.secondary).frame(maxWidth: .infinity).padding(80)
        }
        LazyVGrid(columns: Self.columns, alignment: .leading, spacing: 50) {
            ForEach(items) { Tile(item: $0) }
        }
        .focusSection()
    }

    /// The stored pick is per device, so a chip this profile lacks, such as an adult's Kids, reads as All.
    private var shown: GridFilter { filters.contains(filter) ? filter : .all }

    private var filters: [GridFilter] {
        GridFilter.allCases.filter { $0 != .kids || app.activeProfile?.kind == .adult }
    }
}

struct MenuLabel: View {
    let key: String
    let value: String

    var body: some View {
        HStack(spacing: 12) {
            Text(key).opacity(0.6)
            Text(value)
            Image(systemName: "chevron.down").font(.system(size: 20, weight: .bold))
        }
    }
}

struct ChipStyle: ButtonStyle {
    let selected: Bool
    var radius: CGFloat?

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 30, weight: .semibold))
            .padding(.horizontal, 26)
            .frame(height: 56)
            .background {
                if let radius {
                    RoundedRectangle(cornerRadius: radius).fill(Theme.control)
                } else {
                    Capsule().fill(selected ? Theme.amber : Theme.control)
                }
            }
            .modifier(FocusLift(radius: radius))
            .modifier(SelectedText(selected: selected))
    }

    private struct SelectedText: ViewModifier {
        let selected: Bool
        func body(content: Content) -> some View {
            if selected { content.foregroundStyle(Theme.ground) } else { content }
        }
    }
}

struct PersonView: View {
    @Environment(CatalogModel.self) private var model
    @Environment(AppModel.self) private var app
    let id: Person.ID
    @State private var found: (Person, [Item])?
    @State private var loaded = false
    @State private var image: UIImage?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 50) {
                if let person = found?.0, let items = found?.1 {
                    HStack(spacing: 40) {
                        Headshot(name: person.name, color: Theme.placeholder(person.id), image: image, size: 160)
                        VStack(alignment: .leading, spacing: 8) {
                            Text(person.name).font(.system(size: 64, weight: .bold))
                            Text(items.count == 1 ? "1 title" : "\(items.count) titles").font(.system(size: 30))
                                .foregroundStyle(Theme.secondary)
                        }
                    }
                    LazyVGrid(columns: GridView.columns, alignment: .leading, spacing: 50) {
                        ForEach(items) { Tile(item: model.catalog.item($0.id) ?? $0) }
                    }
                } else if loaded {
                    Text("Not available").font(.system(size: 34)).foregroundStyle(Theme.secondary)
                } else {
                    ProgressView().frame(maxWidth: .infinity).padding(80)
                }
            }
            .padding(Theme.safeArea)
        }
        .scrollClipDisabled()
        .background(Theme.ground)
        .ignoresSafeArea()
        .task(id: id) {
            found = await model.person(id)
            loaded = true
            if found?.0.profilePath != nil {
                image = await app.artwork?.headshotImage(id, maxPixel: 320).map(UIImage.init(cgImage:))
            }
        }
    }
}
