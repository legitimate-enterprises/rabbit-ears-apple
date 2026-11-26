import RabbitEarsAPI
import RabbitEarsKit
import SwiftUI

/// The ellipsis, search and profile buttons at the top of an album, artist, channel or video page.
struct MoreToolbar<Items: View>: ToolbarContent {
    @ViewBuilder var menu: Items

    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            SwiftUI.Menu {
                menu
            } label: {
                Image(systemName: "ellipsis")
            }
            .accessibilityLabel("More")
        }
        BrowseToolbar()
    }
}

struct PlayShuffle: View {
    var playTitle = "Play"
    let play: () -> Void
    var shuffle: (() -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            Button(action: play) {
                Label(playTitle, systemImage: "play.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryButtonStyle(fullWidth: true))
            if let shuffle {
                Button(action: shuffle) {
                    Label("Shuffle", systemImage: "shuffle").frame(maxWidth: .infinity)
                }
                .buttonStyle(SecondaryButtonStyle(fullWidth: true))
            }
        }
    }
}

struct AlbumView: View {
    @Environment(Services.self) private var services
    @Environment(Browser.self) private var browser
    let id: Int64
    @State private var detail: AlbumDetail?
    @State private var failure: String?
    @State private var target: PlaylistTarget?

    var body: some View {
        ScrollView {
            if let detail {
                content(detail)
            } else if let failure {
                ErrorNote(text: failure) { Task { await load() } }
            } else {
                ProgressView().frame(maxWidth: .infinity).padding(60)
            }
        }
        .pulling { await load() }
        .background(Theme.ground)
        .navigationBarTitleDisplayMode(.inline)
        .addToPlaylist($target)
        .toolbar {
            MoreToolbar {
                if let album = detail?.album {
                    Button("Go to artist", systemImage: "music.mic") { browser.open(.artist(album.artistId)) }
                    AddToButtons(target: $target, itemIds: [album.id], kind: .music)
                    DownloadMenu(.album(album))
                }
            }
        }
        .task(id: id) { await load() }
    }

    private func load() async {
        do {
            detail = try await services.music.album(id)
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
    }

    private func content(_ detail: AlbumDetail) -> some View {
        let album = detail.album
        return VStack(alignment: .leading, spacing: 22) {
            VStack(spacing: 14) {
                ArtSquare(id: album.id, radius: 10, placeholder: .album).frame(width: 220)
                VStack(spacing: 6) {
                    Text(album.title).font(.system(size: 26, weight: .bold)).multilineTextAlignment(.center)
                        .accessibilityAddTraits(.isHeader)
                    HStack(spacing: 10) {
                        Button(album.artistName) { browser.open(.artist(album.artistId)) }
                            .buttonStyle(.plain).foregroundStyle(Theme.amber).fontWeight(.semibold)
                        ForEach(
                            ([album.year.map(String.init)]
                                + Format.songs(album.songCount, durationMs: album.durationMs)
                                .components(separatedBy: " · ").map { Optional($0) }).compactMap { $0 },
                            id: \.self
                        ) { Text($0) }
                        if album.lossless { Tag(text: "Lossless") }
                    }
                    .font(.system(size: 13)).foregroundStyle(Theme.secondary)
                }
                PlayShuffle(
                    play: { play(detail, from: 0, shuffled: false) }, shuffle: { play(detail, from: 0, shuffled: true) }
                )
            }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(detail.discs, id: \.self) { disc in
                    if detail.discs.count > 1 {
                        Text("Disc \(disc)").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.secondary)
                            .padding(.vertical, 8)
                    }
                    ForEach(
                        Array(detail.songs.enumerated()).filter { ($0.element.discNumber ?? 1) == disc },
                        id: \.element.id
                    ) {
                        index, song in
                        SongRow(song: song, number: song.trackNumber ?? index + 1, target: $target) {
                            play(detail, from: index, shuffled: false)
                        }
                    }
                }
            }
            if !detail.moreByArtist.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("More by \(album.artistName)").font(.system(size: 17, weight: .bold))
                    AlbumStrip(albums: detail.moreByArtist)
                }
            }
        }
        .padding(EdgeInsets(top: 4, leading: 16, bottom: 20, trailing: 16))
    }

    private func play(_ detail: AlbumDetail, from index: Int, shuffled: Bool) {
        Task { await services.player.play(detail.songs, from: index, source: detail.album.title, shuffled: shuffled) }
    }
}

struct AlbumStrip: View {
    let albums: [MusicAlbum]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 12) {
                ForEach(albums, id: \.id) { AlbumTile(album: $0, detail: $0.year.map(String.init)).frame(width: 110) }
            }
        }
    }
}

struct ArtistView: View {
    @Environment(Services.self) private var services
    let id: Int64
    @State private var detail: ArtistDetail?
    @State private var failure: String?
    @State private var target: PlaylistTarget?

    var body: some View {
        ScrollView {
            if let detail {
                content(detail)
            } else if let failure {
                ErrorNote(text: failure) { Task { await load() } }
            } else {
                ProgressView().frame(maxWidth: .infinity).padding(60)
            }
        }
        .pulling { await load() }
        .background(Theme.ground)
        .navigationBarTitleDisplayMode(.inline)
        .addToPlaylist($target)
        .toolbar {
            MoreToolbar {
                AddToButtons(target: $target, itemIds: [id], kind: .music)
                if let artist = detail?.artist { DownloadMenu(.artist(artist)) }
            }
        }
        .task(id: id) { await load() }
    }

    private func load() async {
        do {
            detail = try await services.music.artist(id)
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
    }

    private func content(_ detail: ArtistDetail) -> some View {
        let artist = detail.artist
        return VStack(alignment: .leading, spacing: 22) {
            VStack(spacing: 14) {
                ArtSquare(id: artist.id, round: true, placeholder: .artist).frame(width: 150)
                VStack(spacing: 6) {
                    Text(artist.name).font(.system(size: 26, weight: .bold)).multilineTextAlignment(.center)
                        .accessibilityAddTraits(.isHeader)
                    HStack(spacing: 10) {
                        Text(artist.albumCount == 1 ? "1 album" : "\(artist.albumCount) albums")
                        Text(artist.songCount == 1 ? "1 song" : "\(artist.songCount) songs")
                        if let genre = artist.genres.first { Text(genre.name) }
                    }
                    .font(.system(size: 13)).foregroundStyle(Theme.secondary)
                }
                PlayShuffle(play: { play(artist, shuffled: false) }, shuffle: { play(artist, shuffled: true) })
                if let overview = artist.overview, !overview.isEmpty {
                    Text(overview).font(.system(size: 14)).foregroundStyle(Theme.synopsis)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if !detail.popular.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Popular").font(.system(size: 17, weight: .bold)).padding(.bottom, 4)
                    ForEach(Array(detail.popular.enumerated()), id: \.element.id) { index, song in
                        SongRow(song: song, number: index + 1, target: $target) {
                            Task {
                                await services.player.play(
                                    detail.popular, from: index, source: "\(artist.name) · Popular")
                            }
                        }
                    }
                }
            }
            if !detail.albums.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Albums").font(.system(size: 17, weight: .bold))
                    LazyVGrid(columns: GridView.columns, spacing: 14) {
                        ForEach(detail.albums, id: \.id) { AlbumTile(album: $0, detail: $0.year.map(String.init)) }
                    }
                }
            }
        }
        .padding(EdgeInsets(top: 4, leading: 16, bottom: 20, trailing: 16))
    }

    private func play(_ artist: MusicArtist, shuffled: Bool) {
        Task {
            guard let songs = try? await services.music.songs(byArtist: artist.id) else { return }
            await services.player.play(songs, source: artist.name, shuffled: shuffled)
        }
    }
}
