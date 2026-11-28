import RabbitEarsAPI
import RabbitEarsKit
import SwiftUI

struct MusicScreen: View {
    @Environment(AppModel.self) private var app
    @Environment(Browser.self) private var browser
    @Environment(PlaylistsModel.self) private var playlists: PlaylistsModel?
    @AppStorage("music.tab") private var stored = MusicTab.albums
    @AppStorage("music.albumSort") private var sort = MusicAlbumSort.added
    @State private var genre: Genre.ID?
    @State private var board: MusicBoard?
    @State private var selection = Selection()

    /// The stored pick is per device, so a tab this profile lacks reads as Albums.
    private var tab: MusicTab { tabs.contains(stored) ? stored : .albums }
    private var tabs: [MusicTab] { MusicTab.tabs(playlists: playlists?.offersView(.music) == true) }
    private var genres: [Genre] { board?.genres ?? [] }
    private var albums: Pager<MusicAlbum>? { board?.albums }
    private var artists: Pager<MusicArtist>? { board?.artists }
    private var songs: Pager<MusicSong>? { board?.songs }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ViewTabs(
                    options: tabs, label: \.rawValue,
                    selection: Binding(get: { tab }, set: { stored = $0 }))
                HStack(spacing: 8) {
                    if tab != .playlists && tab != .stations { DownloadedChip() }
                    Spacer()
                    if tab == .albums {
                        Picker("Sort", selection: $sort) {
                            ForEach(MusicAlbumSort.allCases, id: \.self) { Text($0.title) }
                        }
                        .fixedSize()
                    }
                    if tab != .playlists && tab != .stations && !genres.isEmpty {
                        Picker("Genre", selection: $genre) {
                            Text("Any").tag(Genre.ID?.none)
                            ForEach(genres) { Text($0.name).tag(Optional($0.id)) }
                        }
                        .fixedSize()
                    }
                    if let selectKind { SelectButton(selection: selection, kind: selectKind) }
                }
                if downloadedOnly && order.isEmpty && done {
                    Text("Nothing downloaded here yet.").foregroundStyle(Theme.secondary)
                }
                switch tab {
                case .albums: albumGrid
                case .artists: artistGrid
                case .playlists: PlaylistGrid(kind: .music)
                case .songs: songList
                case .stations: StationGrid(kind: .music)
                }
            }
            .padding(EdgeInsets(top: 10, leading: 22, bottom: 24, trailing: 22))
        }
        .selectionBar(selection, selectKind ?? .album, order: order)
        .onChange(of: tab) { selection.end() }
        .navigationSubtitle(subtitle)
        .task(id: "\(tab.rawValue)/\(sort.rawValue)/\(genre?.description ?? "")/\(downloadedOnly)") {
            guard let music = app.musicModel else { return }
            let board = board ?? MusicBoard(music: music)
            if self.board == nil {
                self.board = board
                Task { await board.loadGenres() }
            }
            await board.load(tab, sort: sort, genre: genre, onDevice: app.downloadedFilter)
        }
        // A change the server tells of refreshes the rows in place; the scroll position stays.
        .task(id: browser.revision) { await board?.refresh(tab) }
    }

    private var subtitle: String {
        func count(_ pager: Pager<some Sendable>?, _ noun: String) -> String {
            guard let pager else { return "" }
            return "\(pager.countText) \(noun)"
        }
        switch tab {
        case .albums: return count(albums, "albums")
        case .artists: return count(artists, "artists")
        case .songs: return count(songs, "songs")
        case .playlists: return "\(playlists?.playlists(.music).count ?? 0) playlists"
        case .stations: return ""
        }
    }

    private var selectKind: SelectKind? {
        switch tab {
        case .albums: .album
        case .artists: .artist
        case .songs: .song
        case .playlists, .stations: nil
        }
    }

    private var order: [UID] {
        switch tab {
        case .albums: (albums?.items ?? []).map(\.id)
        case .artists: (artists?.items ?? []).map(\.id)
        case .songs: (songs?.items ?? []).map(\.id)
        case .playlists, .stations: []
        }
    }

    private var downloadedOnly: Bool { app.downloads?.downloadedOnly == true }

    /// The tab's listing has been read to its end.
    private var done: Bool {
        switch tab {
        case .albums: albums?.done == true
        case .artists: artists?.done == true
        case .songs: songs?.done == true
        case .playlists, .stations: false
        }
    }

    private var columns: [GridItem] { [GridItem(.adaptive(minimum: 123), spacing: 14, alignment: .top)] }

    private var albumGrid: some View {
        let order = order
        return LazyVGrid(columns: columns, spacing: 16) {
            ForEach(albums?.items ?? [], id: \.id) { AlbumTile(album: $0).selectable(selection, $0.id, in: order) }
        }
    }

    private var artistGrid: some View {
        let order = order
        return LazyVGrid(columns: columns, spacing: 16) {
            ForEach(artists?.items ?? [], id: \.id) { ArtistTile(artist: $0).selectable(selection, $0.id, in: order) }
        }
    }

    private var songList: some View {
        LazyVStack(spacing: 0) {
            let loaded = songs?.items ?? []
            let order = loaded.map(\.id)
            ForEach(Array(loaded.enumerated()), id: \.element.id) { index, song in
                SongRow(song: song, queue: loaded, index: index, source: "Songs", showsAlbum: true)
                    .selectable(selection, song.id, in: order)
                    .onAppear { if index == loaded.count - 1 { Task { await songs?.loadMore() } } }
            }
        }
    }

}

struct AlbumTile: View {
    @Environment(AppModel.self) private var app
    @Environment(Browser.self) private var browser
    @Environment(MusicPlayer.self) private var player
    let album: MusicAlbum
    /// Under the title; nil shows the artist.
    var caption: String?

    var body: some View {
        Button {
            browser.open(.album(album.id))
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Art(id: album.id, placeholder: .album)
                Text(album.title).font(.system(size: 12, weight: .semibold)).lineLimit(2)
                Text(caption ?? album.artistName).font(.system(size: 11)).foregroundStyle(Theme.secondary)
                    .lineLimit(1)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .dimmedOffline(album.id)
        .contextMenu {
            Button("Play") { play(shuffled: false) }.needsServer(.play, album.id)
            Button("Shuffle") { play(shuffled: true) }.needsServer(.play, album.id)
            Button("Go to artist") { browser.open(.artist(album.artistId)) }
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
            VStack(spacing: 6) {
                Art(id: artist.id, circle: true, placeholder: .artist)
                Text(artist.name).font(.system(size: 12, weight: .semibold)).lineLimit(2)
                Text("\(artist.albumCount) albums").font(.system(size: 11)).foregroundStyle(Theme.secondary)
            }
            .multilineTextAlignment(.center)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .dimmedOffline(artist.id)
        .contextMenu { FavoriteMenuItem(id: artist.id) }
    }
}

struct SongRow: View {
    @Environment(AppModel.self) private var app
    @Environment(MusicPlayer.self) private var player
    let song: MusicSong
    let queue: [MusicSong]
    let index: Int
    let source: String
    var playlistId: UID?
    /// Disc track numbers lead an album's rows; artist and album lead the others.
    var numbered = false
    /// Artist's Popular numbers its rows by rank rather than by track.
    var rank: Int?
    var showsAlbum = false

    var body: some View {
        let current = player.current?.id == song.id
        Button {
            guard !app.needsServer(.play, song.id) else { return }
            Task { await player.play(queue, from: index, source: source, playlistId: playlistId) }
        } label: {
            HStack(spacing: 14) {
                if numbered {
                    Text("\(rank ?? song.trackNumber ?? index + 1)").frame(width: 28, alignment: .trailing)
                        .foregroundStyle(current ? Theme.amber : Theme.secondary)
                } else {
                    Art(id: song.albumId, radius: 4, placeholder: .album, badges: StatusBadges(id: song.id)).frame(
                        width: 36, height: 36)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(song.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        .foregroundStyle(current ? Theme.amber : Theme.primary)
                    if !numbered {
                        Text(showsAlbum ? "\(song.artistName) · \(song.albumTitle)" : song.artistName)
                            .font(.system(size: 12)).foregroundStyle(Theme.secondary).lineLimit(1)
                    }
                }
                Spacer()
                Text(Format.clock(seconds: Double(song.durationMs ?? 0) / 1000)).monospacedDigit()
                    .font(.system(size: 13)).foregroundStyle(Theme.secondary)
            }
            .padding(.vertical, numbered ? 7 : 6).padding(.horizontal, 10)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .dimmedOffline(song.id)
        .contextMenu {
            FavoriteMenuItem(id: song.id)
            PlaylistMenu(itemId: song.id, kind: .music)
            DownloadMenu(.song(song))
        }
    }
}
