import RabbitEarsAPI
import RabbitEarsKit
import SwiftUI

struct SearchView: View {
    @Environment(CatalogModel.self) private var model
    @Environment(Services.self) private var services
    @Environment(Browser.self) private var browser
    @State private var search = ""
    @State private var results: SearchResult?
    @State private var target: PlaylistTarget?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if let results, !query.isEmpty {
                    if results.sections.isEmpty { EmptyNote(text: "Nothing matches “\(query)”.") }
                    ForEach(results.sections, id: \.self) { section in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(section.rawValue).font(.system(size: 17, weight: .bold))
                            content(section, results)
                        }
                    }
                } else if !query.isEmpty {
                    ProgressView().frame(maxWidth: .infinity).padding(40)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(EdgeInsets(top: 4, leading: 20, bottom: 20, trailing: 20))
        }
        .background(Theme.ground)
        .navigationTitle("Search")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search")
        .addToPlaylist($target)
        .toolbar { BrowseToolbar(search: false) }
        .task(id: query) {
            guard !query.isEmpty else { return }
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            let found = await model.search(query)
            if !Task.isCancelled { results = found ?? .empty }
        }
    }

    private var query: String { search.trimmingCharacters(in: .whitespaces) }

    @ViewBuilder
    private func content(_ section: SearchSection, _ results: SearchResult) -> some View {
        switch section {
        case .movies: titles(results.movies)
        case .tv: titles(results.tv)
        case .people:
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(results.people) { person in
                        PersonCircle(
                            id: person.id, name: person.name, detail: nil, headshot: person.headshotUrl)
                    }
                }
            }
        case .artists:
            ForEach(results.artists, id: \.id) { artist in
                Button(artist.name) { browser.open(.artist(artist.id)) }
                    .buttonStyle(.plain).font(.system(size: 15, weight: .semibold))
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
            }
        case .albums:
            LazyVGrid(columns: GridView.columns, spacing: 14) {
                ForEach(results.albums, id: \.id) { AlbumTile(album: $0) }
            }
        case .songs:
            ForEach(Array(results.songs.enumerated()), id: \.element.id) { index, song in
                SongRow(song: song, art: true, target: $target) {
                    Task { await services.player.play(results.songs, from: index, source: "Search") }
                }
            }
        case .channels: ChannelsGrid(channels: results.channels)
        case .videos:
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12, alignment: .top)], spacing: 14) {
                ForEach(results.videos, id: \.id) { VideoTile(video: $0) }
            }
        }
    }

    private func titles(_ items: [Item]) -> some View {
        LazyVGrid(columns: GridView.columns, spacing: 14) {
            ForEach(items) { Tile(item: model.catalog.item($0.id) ?? $0) }
        }
    }
}

struct SearchButton: View {
    @Environment(Browser.self) private var browser

    var body: some View {
        Button {
            browser.search()
        } label: {
            Image(systemName: "magnifyingglass")
        }.accessibilityLabel("Search")
    }
}
