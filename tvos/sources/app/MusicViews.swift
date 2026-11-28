import RabbitEarsAPI
import RabbitEarsKit
import SwiftUI

extension AppModel {
    var musicModel: MusicModel? {
        guard let client, let sync, let activeProfile else { return nil }
        return MusicModel(client: client, replica: sync.replica, profileId: activeProfile.id)
    }
    var youTubeModel: YouTubeModel? {
        guard let client, let sync, let activeProfile else { return nil }
        return YouTubeModel(client: client, replica: sync.replica, queue: sync.queue, profileId: activeProfile.id)
    }
}

struct MusicScreen: View {
    @Environment(AppModel.self) private var app
    @Environment(Browser.self) private var browser
    @Environment(PlaylistsModel.self) private var playlists
    @Environment(MusicPlayer.self) private var player
    @AppStorage("music.chip") private var tab = MusicTab.albums
    @AppStorage("music.sort") private var sort = MusicAlbumSort.added
    @State private var genre: Genre.ID?
    @State private var board: MusicBoard?
    @State private var stations: [Station]?

    var body: some View {
        let musicCount = playlists.playlists(.music).count
        ScrollView {
            VStack(alignment: .leading, spacing: 44) {
                ViewTabs(
                    options: MusicTab.tabs(playlists: playlists.offersView(.music)), label: \.rawValue,
                    selection: $tab)
                HStack(spacing: 16) {
                    Text(board?.caption(tab, playlists: musicCount, stations: stations?.count) ?? "").font(
                        .system(size: 30)
                    )
                    .foregroundStyle(Theme.secondary)
                    Spacer()
                    if tab == .albums {
                        Menu {
                            Picker("Sort", selection: $sort) {
                                ForEach(MusicAlbumSort.allCases, id: \.self) { Text($0.title) }
                            }
                        } label: {
                            MenuLabel(key: "Sort", value: sort.title)
                        }
                    }
                    if tab != .playlists, tab != .stations, let genres = board?.genres, !genres.isEmpty {
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
                .buttonStyle(ChipStyle(selected: false, radius: 12))
                .focusSection()
                content
            }
            .padding(EdgeInsets(top: shellTop + 8, leading: 80, bottom: 60, trailing: 80))
        }
        .scrollClipDisabled()
        .task(id: "\(tab.rawValue)/\(sort.rawValue)/\(genre?.description ?? "")") {
            // The tab is remembered per device, so an adult's Playlists may be what a kid finds.
            if !MusicTab.tabs(playlists: playlists.offersView(.music)).contains(tab) { tab = .albums }
            guard let model = app.musicModel else { return }
            let board = board ?? MusicBoard(music: model)
            if self.board == nil {
                self.board = board
                Task { await board.loadGenres() }
                Task { await playlists.load() }
            }
            await board.load(tab, sort: sort, genre: genre)
        }
        .task(id: browser.returns) { await board?.refresh(tab) }
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .albums:
            LazyVGrid(columns: GridView.columns, alignment: .leading, spacing: 50) {
                ForEach(board?.albums?.items ?? [], id: \.id) { AlbumTile(album: $0) }
            }
            .focusSection()
        case .artists:
            LazyVGrid(columns: GridView.columns, alignment: .leading, spacing: 50) {
                ForEach(board?.artists?.items ?? [], id: \.id) { ArtistTile(artist: $0) }
            }
            .focusSection()
        case .playlists: PlaylistTiles(kind: .music)
        case .stations: StationTiles(kind: .music, list: $stations)
        case .songs:
            let songs = board?.songs?.items ?? []
            LazyVStack(spacing: 8) {
                ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
                    TrackRow(song: song, detail: "\(song.artistName) · \(song.albumTitle)") {
                        Task { await player.play(songs, from: index, source: "Songs") }
                    }
                    .onAppear { if index >= songs.count - 8 { Task { await board?.songs?.loadMore() } } }
                }
            }
            .focusSection()
        }
    }
}

struct AlbumTile: View {
    @Environment(AppModel.self) private var app
    @Environment(Browser.self) private var browser
    @Environment(MusicPlayer.self) private var player
    let album: MusicAlbum
    /// Under the title in place of the artist.
    var caption: String?

    var body: some View {
        Button {
            browser.open(.album(album.id))
        } label: {
            VStack(alignment: .leading, spacing: 14) {
                ArtBlock(id: album.id, placeholder: .album)
                VStack(alignment: .leading, spacing: 2) {
                    Text(album.title).font(.system(size: 28, weight: .semibold)).lineLimit(2, reservesSpace: true)
                    Text(caption ?? album.artistName).font(.system(size: 26)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .buttonStyle(CardButtonStyle())
        .contextMenu {
            Button("Play", systemImage: "play.fill") { play(shuffled: false) }
            Button("Shuffle", systemImage: "shuffle") { play(shuffled: true) }
            FavoriteMenuItem(id: album.id)
        }
    }

    private func play(shuffled: Bool) {
        Task {
            guard let detail = try? await app.musicModel?.album(album.id) else { return }
            await player.play(detail.songs, source: album.title, shuffled: shuffled)
        }
    }
}

struct ArtistTile: View {
    @Environment(Browser.self) private var browser
    let artist: MusicArtist

    var body: some View {
        Button {
            browser.open(.artist(artist.id))
        } label: {
            VStack(spacing: 14) {
                ArtBlock(id: artist.id, radius: 130, placeholder: .artist).frame(width: 220)
                Text(artist.name).font(.system(size: 28, weight: .semibold)).lineLimit(1)
                Text(artist.albumCount == 1 ? "1 album" : "\(artist.albumCount) albums").font(.system(size: 26))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(CardButtonStyle())
    }
}

/// Marks the song that is playing.
struct BarsIcon: View {
    var body: some View {
        HStack(alignment: .bottom, spacing: 3) {
            ForEach([14.0, 22.0, 10.0], id: \.self) { height in
                RoundedRectangle(cornerRadius: 1.5).fill(Theme.amber).frame(width: 5, height: height)
            }
        }
        .frame(height: 24)
        .accessibilityHidden(true)
    }
}

struct TrackRow: View {
    @Environment(MusicPlayer.self) private var player
    let song: MusicSong
    var number: Int?
    var detail: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            TrackLine(
                song: song, number: number, detail: detail,
                playing: player.stream != nil && player.current?.id == song.id)
        }
        .buttonStyle(RowButtonStyle(radius: 14, scale: 1.02))
    }
}

private struct TrackLine: View {
    @Environment(\.isFocused) private var focused
    let song: MusicSong
    let number: Int?
    let detail: String?
    let playing: Bool

    var body: some View {
        HStack(spacing: 24) {
            Group {
                if playing {
                    BarsIcon()
                } else if let number {
                    Text("\(number)").foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 30))
            .frame(width: 56, alignment: .trailing)
            VStack(alignment: .leading, spacing: 2) {
                Text(song.title).font(.system(size: 32, weight: .semibold)).lineLimit(1)
                    .foregroundStyle(playing && !focused ? AnyShapeStyle(Theme.amber) : AnyShapeStyle(.primary))
                if let detail { Text(detail).font(.system(size: 26)).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer(minLength: 20)
            Text(song.durationMs.map { Format.clock(seconds: Double($0) / 1000) } ?? "").font(.system(size: 30))
                .foregroundStyle(.secondary).monospacedDigit()
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct NowPlayingChip: View {
    @Environment(MusicPlayer.self) private var player
    @Environment(Browser.self) private var browser

    var body: some View {
        if let song = player.current, player.stream != nil {
            Button {
                browser.open(.nowPlaying)
            } label: {
                HStack(spacing: 16) {
                    ArtBlock(id: song.albumId, radius: 26, placeholder: .album).frame(width: 52)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(song.title).font(.system(size: 28, weight: .semibold)).lineLimit(1)
                        Text(song.artistName).font(.system(size: 26)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .frame(maxWidth: 300, alignment: .leading)
                    BarsIcon()
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Theme.bar, in: .capsule)
                .modifier(FocusLift(scale: 1.05))
            }
            .buttonStyle(BareButtonStyle())
            .accessibilityLabel("Now playing: \(song.title), \(song.artistName)")
        }
    }
}

/// Fixed to the top left of a screen that has no top bar.
struct ChipCorner: ViewModifier {
    func body(content: Content) -> some View {
        content.overlay(alignment: .topLeading) { NowPlayingChip().padding(Theme.safeArea) }
    }
}
