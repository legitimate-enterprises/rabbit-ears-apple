import RabbitEarsAPI
import RabbitEarsKit
import SwiftUI

/// The profile's stars by kind, each most recently starred first.
struct FavoritesView: View {
    @Environment(AppModel.self) private var app
    @Environment(MusicPlayer.self) private var player
    @State private var shelves: FavoriteShelves?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 50) {
                if let shelves {
                    if shelves.sections.isEmpty {
                        Text("Nothing starred yet. Favorite is beside a title's Play or in its menu.")
                            .font(.system(size: 30)).foregroundStyle(Theme.secondary)
                            .frame(maxWidth: .infinity).padding(60)
                    }
                    ForEach(shelves.sections, id: \.self) { section in
                        VStack(alignment: .leading, spacing: 24) {
                            Text(section.rawValue).font(.system(size: 34, weight: .bold))
                            content(section, shelves)
                        }
                        .focusSection()
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity).padding(60)
                }
            }
            .padding(EdgeInsets(top: shellTop + 8, leading: 80, bottom: 60, trailing: 80))
        }
        .scrollClipDisabled()
        .task(id: app.live.favorites) { shelves = await app.favoriteShelves() ?? FavoriteShelves() }
    }

    @ViewBuilder
    private func content(_ section: FavoriteSection, _ shelves: FavoriteShelves) -> some View {
        switch section {
        case .movies: grid { ForEach(shelves.movies) { Tile(item: $0) } }
        case .shows: grid { ForEach(shelves.shows) { Tile(item: $0) } }
        case .seasons: grid { ForEach(shelves.seasons) { SeasonTile(item: $0) } }
        case .episodes:
            LazyVGrid(columns: videoColumns, alignment: .leading, spacing: 50) {
                ForEach(shelves.episodes) { Tile(item: $0, wide: true) }
            }
        case .artists: grid { ForEach(shelves.artists, id: \.id) { ArtistTile(artist: $0) } }
        case .albums: grid { ForEach(shelves.albums, id: \.id) { AlbumTile(album: $0) } }
        case .songs:
            LazyVStack(spacing: 8) {
                ForEach(Array(shelves.songs.enumerated()), id: \.element.id) { index, song in
                    TrackRow(song: song, detail: "\(song.artistName) · \(song.albumTitle)") {
                        Task { await player.play(shelves.songs, from: index, source: "Favorites") }
                    }
                }
            }
        case .videos:
            LazyVGrid(columns: videoColumns, alignment: .leading, spacing: 50) {
                ForEach(shelves.videos, id: \.id) { VideoTile(video: $0) }
            }
        }
    }

    private func grid(@ViewBuilder _ tiles: () -> some View) -> some View {
        LazyVGrid(columns: GridView.columns, alignment: .leading, spacing: 50, content: tiles)
    }
}

/// A details screen's star, its only favorites control.
struct FavoriteButton: View {
    @Environment(AppModel.self) private var app
    let id: UID

    var body: some View {
        let on = app.favorites.contains(id)
        Button {
            Task { await app.setFavorite(!on, id) }
        } label: {
            Star(on: on)
        }
        .buttonStyle(TVButtonStyle())
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    /// Amber while on, except under focus, where FocusLift's dark text reads on its light fill.
    private struct Star: View {
        @Environment(\.isFocused) private var focused
        let on: Bool

        var body: some View {
            let label = Label("Favorite", systemImage: on ? "star.fill" : "star")
            if on && !focused { label.foregroundStyle(Theme.amber) } else { label }
        }
    }
}

/// A tile's long-press item, where no star is on screen.
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
