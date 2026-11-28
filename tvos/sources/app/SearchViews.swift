import RabbitEarsAPI
import RabbitEarsKit
import SwiftUI

struct SearchView: View {
    @Environment(CatalogModel.self) private var model
    @Environment(MusicPlayer.self) private var player
    @State private var search = ""
    @State private var results: SearchResult?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 50) {
                TextField("Search", text: $search, prompt: Text("Movies, shows, music, videos and people"))
                    .autocorrectionDisabled().font(.system(size: 34)).frame(width: 1000)
                    .frame(maxWidth: .infinity)
                if let results, !query.isEmpty {
                    if results.sections.isEmpty {
                        Text("Nothing matches “\(query)”.").font(.system(size: 30)).foregroundStyle(Theme.secondary)
                            .frame(maxWidth: .infinity).padding(60)
                    }
                    ForEach(results.sections, id: \.self) { section in
                        VStack(alignment: .leading, spacing: 24) {
                            Text(section.rawValue).font(.system(size: 34, weight: .bold))
                            content(section, results)
                        }
                        .focusSection()
                    }
                } else if !query.isEmpty {
                    ProgressView().frame(maxWidth: .infinity).padding(60)
                }
            }
            .padding(EdgeInsets(top: shellTop + 8, leading: 80, bottom: 60, trailing: 80))
        }
        .scrollClipDisabled()
        .task(id: query) {
            guard !query.isEmpty else { return }
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            let found = await model.search(query) ?? .empty
            if !Task.isCancelled { results = found }
        }
    }

    private var query: String { search.trimmingCharacters(in: .whitespaces) }

    @ViewBuilder
    private func content(_ section: SearchSection, _ results: SearchResult) -> some View {
        switch section {
        case .movies: grid { ForEach(results.movies) { Tile(item: model.catalog.item($0.id) ?? $0) } }
        case .tv: grid { ForEach(results.tv) { Tile(item: model.catalog.item($0.id) ?? $0) } }
        case .people:
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 48) {
                    ForEach(results.people) { person in
                        PersonCircle(
                            id: person.id, name: person.name, detail: nil, headshot: person.headshotUrl)
                    }
                }
                .padding(.vertical, 20)
            }
            .scrollClipDisabled()
        case .artists: grid { ForEach(results.artists, id: \.id) { ArtistTile(artist: $0) } }
        case .albums: grid { ForEach(results.albums, id: \.id) { AlbumTile(album: $0) } }
        case .songs:
            LazyVStack(spacing: 8) {
                ForEach(Array(results.songs.enumerated()), id: \.element.id) { index, song in
                    TrackRow(song: song, detail: "\(song.artistName) · \(song.albumTitle)") {
                        Task { await player.play(results.songs, from: index, source: "Search") }
                    }
                }
            }
        case .channels: grid { ForEach(results.channels, id: \.id) { ChannelTile(channel: $0) } }
        case .videos:
            LazyVGrid(columns: videoColumns, alignment: .leading, spacing: 50) {
                ForEach(results.videos, id: \.id) { VideoTile(video: $0) }
            }
        }
    }

    private func grid(@ViewBuilder _ tiles: () -> some View) -> some View {
        LazyVGrid(columns: GridView.columns, alignment: .leading, spacing: 50, content: tiles)
    }
}
