import RabbitEarsAPI
import RabbitEarsKit
import SwiftUI

/// One kind of the profile's favorites, most recently starred first.
struct FavoriteScreen: View {
    @Environment(AppModel.self) private var app
    @Environment(CatalogModel.self) private var model
    let section: FavoriteSection
    /// Called once the profile has no favorite of this kind left, as the sidebar then lists none.
    let gone: () -> Void
    @State private var shelves: FavoriteShelves?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let shelves {
                    if shelves.count(section) == 0 {
                        Text("Nothing starred yet. Favorite is beside a title's Play or in its menu.")
                            .foregroundStyle(Theme.secondary).frame(maxWidth: .infinity).padding(40)
                    }
                    content(shelves)
                }
            }
            .padding(EdgeInsets(top: 10, leading: 22, bottom: 24, trailing: 22))
        }
        .navigationSubtitle(shelves.map { "\($0.count(section)) \(section.rawValue.lowercased())" } ?? "")
        .task(id: "\(section.rawValue)/\(app.live.favorites)") { shelves = await app.favoriteShelves(only: section) }
        .task(id: app.favorites.sections) { if !app.favorites.sections.contains(section) { gone() } }
    }

    @ViewBuilder
    private func content(_ shelves: FavoriteShelves) -> some View {
        switch section {
        case .movies: titles(shelves.movies)
        case .shows: titles(shelves.shows)
        case .episodes: titles(shelves.episodes)
        case .seasons: grid(120) { ForEach(shelves.seasons) { SeasonTile(item: model.catalog.item($0.id) ?? $0) } }
        case .artists: grid(123) { ForEach(shelves.artists, id: \.id) { ArtistTile(artist: $0) } }
        case .albums: grid(123) { ForEach(shelves.albums, id: \.id) { AlbumTile(album: $0) } }
        case .songs:
            LazyVStack(spacing: 0) {
                ForEach(Array(shelves.songs.enumerated()), id: \.element.id) { index, song in
                    SongRow(song: song, queue: shelves.songs, index: index, source: "Favorites", showsAlbum: true)
                }
            }
        case .videos: grid(224) { ForEach(shelves.videos, id: \.id) { VideoTile(video: $0) } }
        }
    }

    /// Episodes show as their show's, with the catalog's watch marks.
    private func titles(_ items: [Item]) -> some View {
        grid(120) { ForEach(items) { Tile(item: model.catalog.item($0.id) ?? $0) } }
    }

    private func grid<Content: View>(_ minimum: CGFloat, @ViewBuilder _ content: () -> Content) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: minimum), spacing: 14, alignment: .top)], spacing: 16) {
            content()
        }
    }
}

/// The sidebar's Favorites: a row per kind the profile has starred, absent with none.
struct FavoritesSidebarSection: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        if !app.favorites.sections.isEmpty {
            Section {
                ForEach(app.favorites.sections, id: \.self) { Text($0.rawValue).tag(SidebarSection.favorites($0)) }
            } header: {
                Text("Favorites")
            }
        }
    }
}

/// Favorite beside a title's Play: a star, filled amber once the profile has starred it.
struct FavoriteButton: View {
    @Environment(AppModel.self) private var app
    let id: UID
    /// Beside Now Playing's Shuffle and Repeat, which are named too.
    var titled = false

    var body: some View {
        let on = app.favorites.contains(id)
        let icon = on ? "star.fill" : "star"
        Button {
            Task { await app.setFavorite(!on, id) }
        } label: {
            Group {
                if titled { Label("Favorite", systemImage: icon) } else { Image(systemName: icon) }
            }
            .foregroundStyle(on ? Theme.amber : .white)
        }
        .buttonStyle(SecondaryButtonStyle()).fixedSize()
        .help("Favorite")
        .accessibilityLabel("Favorite")
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// Add to or Remove from Favorites, in a tile's or row's menu, where no star is on screen.
struct FavoriteMenuItem: View {
    @Environment(AppModel.self) private var app
    let id: UID

    var body: some View {
        let on = app.favorites.contains(id)
        Button {
            Task { await app.setFavorite(!on, id) }
        } label: {
            Label(on ? "Remove from Favorites" : "Add to Favorites", systemImage: on ? "star.slash" : "star")
        }
    }
}
