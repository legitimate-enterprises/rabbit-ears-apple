import RabbitEarsAPI
import RabbitEarsKit
import SwiftUI

/// The toolbar search across every library: a section for each kind that
/// found anything, in the server's filter for the profile.
struct SearchView: View {
    @Environment(CatalogModel.self) private var model
    let search: String
    @State private var results: SearchResult?
    @State private var failed = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if let results {
                    if results.sections.isEmpty {
                        Text("Nothing matches “\(search)”.").foregroundStyle(Theme.secondary).padding(40)
                    }
                    ForEach(results.sections, id: \.self) { section in
                        VStack(alignment: .leading, spacing: 10) {
                            Heading(text: section.rawValue)
                            content(section, results)
                        }
                    }
                } else if failed {
                    Text("Search isn't available right now.").foregroundStyle(Theme.secondary).padding(40)
                } else {
                    ProgressView().frame(maxWidth: .infinity).padding(40)
                }
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: search) {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            let found = await model.search(search)
            guard !Task.isCancelled else { return }
            results = found
            failed = found == nil
        }
    }

    @ViewBuilder
    private func content(_ section: SearchSection, _ results: SearchResult) -> some View {
        switch section {
        case .movies: titles(results.movies)
        case .tv: titles(results.tv)
        case .people:
            row {
                ForEach(results.people) { person in
                    PersonCircle(id: person.id, name: person.name, detail: nil, headshot: person.headshotUrl)
                }
            }
        case .artists: row { ForEach(results.artists, id: \.id) { ArtistTile(artist: $0).frame(width: 110) } }
        case .albums: row { ForEach(results.albums, id: \.id) { AlbumTile(album: $0).frame(width: 120) } }
        case .songs:
            VStack(spacing: 0) {
                ForEach(Array(results.songs.enumerated()), id: \.element.id) { index, song in
                    SongRow(song: song, queue: results.songs, index: index, source: "Search", showsAlbum: true)
                }
            }
        case .channels: row { ForEach(results.channels, id: \.id) { ChannelTile(channel: $0).frame(width: 130) } }
        case .videos: row { ForEach(results.videos, id: \.id) { VideoTile(video: $0).frame(width: 224) } }
        }
    }

    /// Episodes show as their show's, with the catalog's watch marks.
    private func titles(_ items: [Item]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 14, alignment: .top)], spacing: 16) {
            ForEach(items) { Tile(item: model.catalog.item($0.id) ?? $0) }
        }
    }

    private func row<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 14) { content() }
        }
    }
}
