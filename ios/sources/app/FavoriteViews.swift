import RabbitEarsAPI
import RabbitEarsKit
import SwiftUI

/// Every kind the profile has starred, a section each, most recently starred first.
struct FavoritesView: View {
    @Environment(AppModel.self) private var app
    @Environment(CatalogModel.self) private var model
    @Environment(Services.self) private var services
    @Environment(Browser.self) private var browser
    @State private var shelves: FavoriteShelves?
    @State private var target: PlaylistTarget?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if let shelves {
                    if shelves.sections.isEmpty {
                        EmptyNote(text: "Nothing starred yet. Favorite is beside a title\u{2019}s Play or in its menu.")
                    }
                    ForEach(shelves.sections, id: \.self) { section in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(section.rawValue).font(.system(size: 17, weight: .bold))
                            content(section, shelves)
                        }
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity).padding(40)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(EdgeInsets(top: 4, leading: 20, bottom: 20, trailing: 20))
        }
        .background(Theme.ground)
        .navigationTitle("Favorites")
        .navigationBarTitleDisplayMode(.inline)
        .addToPlaylist($target)
        .toolbar { BrowseToolbar(favorites: false) }
        .task(id: app.live.favorites) { shelves = await app.favoriteShelves() ?? FavoriteShelves() }
    }

    @ViewBuilder
    private func content(_ section: FavoriteSection, _ shelves: FavoriteShelves) -> some View {
        switch section {
        case .movies: titles(shelves.movies)
        case .shows: titles(shelves.shows)
        case .seasons:
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 14) { ForEach(shelves.seasons) { SeasonTile(item: $0) } }
            }
        case .episodes: titles(shelves.episodes)
        case .artists:
            ForEach(shelves.artists, id: \.id) { artist in
                Button(artist.name) { browser.open(.artist(artist.id)) }
                    .buttonStyle(.plain).font(.system(size: 15, weight: .semibold))
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
                    .contextMenu { FavoriteMenuItem(id: artist.id) }
            }
        case .albums:
            LazyVGrid(columns: GridView.columns, spacing: 14) {
                ForEach(shelves.albums, id: \.id) { AlbumTile(album: $0) }
            }
        case .songs:
            ForEach(Array(shelves.songs.enumerated()), id: \.element.id) { index, song in
                SongRow(song: song, art: true, target: $target) {
                    Task { await services.player.play(shelves.songs, from: index, source: "Favorites") }
                }
            }
        case .videos:
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12, alignment: .top)], spacing: 14) {
                ForEach(shelves.videos, id: \.id) { VideoTile(video: $0) }
            }
        }
    }

    private func titles(_ items: [Item]) -> some View {
        LazyVGrid(columns: GridView.columns, spacing: 14) {
            ForEach(items) { Tile(item: model.catalog.item($0.id) ?? $0) }
        }
    }
}

struct FavoritesButton: View {
    @Environment(Browser.self) private var browser

    var body: some View {
        Button {
            browser.open(.favorites)
        } label: {
            Image(systemName: "star")
        }.accessibilityLabel("Favorites")
    }
}

/// A detail screen's star: filled and amber while the title is a favorite.
struct FavoriteButton: View {
    @Environment(AppModel.self) private var app
    let id: UID
    /// The square a plain-styled star takes taps in.
    var side: CGFloat?

    var body: some View {
        let on = app.favorites.contains(id)
        Button {
            Task { await app.setFavorite(!on, id) }
        } label: {
            // Off, the star keeps the color of where it sits: tinted in a toolbar, plain on a button.
            Group {
                if on {
                    Image(systemName: "star.fill").foregroundStyle(Theme.amber)
                } else {
                    Image(systemName: "star")
                }
            }
            .frame(width: side, height: side).contentShape(.rect)
        }
        .accessibilityLabel("Favorite")
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// Add to or Remove from Favorites, for long-press menus, where no star is on screen.
struct FavoriteMenuItem: View {
    @Environment(AppModel.self) private var app
    let id: UID

    var body: some View {
        let on = app.favorites.contains(id)
        Button(on ? "Remove from Favorites" : "Add to Favorites", systemImage: on ? "star.slash" : "star") {
            Task { await app.setFavorite(!on, id) }
        }
    }
}
