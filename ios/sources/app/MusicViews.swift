import RabbitEarsAPI
import RabbitEarsKit
import SwiftUI

/// The views a library screen switches between, above its filter chips.
struct ViewTabs<Option: Hashable>: View {
    let options: [Option]
    let title: (Option) -> String
    @Binding var selection: Option

    var body: some View {
        if options.count > 1 {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 20) {
                    ForEach(options, id: \.self) { option in
                        let current = option == selection
                        Button {
                            selection = option
                        } label: {
                            Text(title(option)).font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(current ? Theme.amber : Theme.unselected)
                                .frame(minHeight: 44).contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(current ? .isSelected : [])
                    }
                }
            }
            .contentMargins(.horizontal, 20, for: .scrollContent)
            .padding(.horizontal, -20)
            // The 44pt targets overlap the rows around by 6pt, as the canvas draws them.
            .padding(.vertical, -6)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("View")
        }
    }
}

struct MusicView: View {
    @Environment(Services.self) private var services
    @State private var tab = MusicTab.albums
    @State private var count = ""
    @State private var selection = Selection()
    @State private var reloader = Reloader()
    @AppStorage("music.albumSort") private var albumSort = MusicAlbumSort.added
    @AppStorage("music.songSort") private var songSort = MusicSongSort.title
    @State private var genre: Genre.ID?
    @State private var genres: [Genre] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ViewTabs(
                    options: MusicTab.allCases.filter { $0 != .playlists || services.playlists.offersView(.music) },
                    title: \.rawValue, selection: $tab)
                switch tab {
                case .albums: AlbumsGrid(sort: albumSort, genre: genre, count: $count)
                case .artists: ArtistsList(genre: genre, count: $count)
                case .playlists: PlaylistsList(kind: .music, count: $count)
                case .songs: SongsList(sort: songSort, genre: genre, count: $count)
                case .stations: StationsList(kind: .music, count: $count)
                }
            }
            .padding(EdgeInsets(top: 0, leading: 20, bottom: 20, trailing: 20))
        }
        .environment(reloader)
        .task { genres = (try? await services.music.musicGenres()) ?? [] }
        .pulling {
            if tab == .playlists { await services.playlists.load() } else { await reloader.action?() }
        }
        .selecting(selection, selectKind)
        .countedTitle(LibraryTab.music.rawValue, count: count)
        .toolbar {
            if tab == .albums || tab == .songs || (tab == .artists && !genres.isEmpty) {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        if tab == .albums {
                            Picker("Sort", selection: $albumSort) {
                                ForEach(MusicAlbumSort.allCases, id: \.self) { Text($0.title) }
                            }
                        } else if tab == .songs {
                            Picker("Sort", selection: $songSort) {
                                ForEach(MusicSongSort.allCases, id: \.self) { Text($0.title) }
                            }
                        }
                        if !genres.isEmpty {
                            Picker("Genre", selection: $genre) {
                                Text("Any").tag(Genre.ID?.none)
                                ForEach(genres) { Text($0.name).tag(Optional($0.id)) }
                            }
                        }
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease")
                    }
                    .accessibilityLabel(genres.isEmpty ? "Sort" : "Sort and filter")
                }
            }
            BrowseToolbar()
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
}

/// `1,210`; the listing's own total, so the whole count shows from the first page.
@MainActor
func countText<T>(_ list: Pager<T>?) -> String {
    list?.countText ?? ""
}

struct AlbumsGrid: View {
    @Environment(Services.self) private var services
    @Environment(Browser.self) private var browser
    let sort: MusicAlbumSort
    let genre: Genre.ID?
    @Binding var count: String
    @State private var list: Pager<MusicAlbum>?

    var body: some View {
        VStack(spacing: 16) {
            if let list {
                if list.items.isEmpty && list.done { EmptyNote(text: "No music yet.") }
                LazyVGrid(columns: GridView.columns, spacing: 14) {
                    ForEach(list.items, id: \.id) { album in
                        AlbumTile(album: album)
                            .selectable(album.id)
                            .onAppear { if album.id == list.items.last?.id { Task { await list.loadMore() } } }
                    }
                }
                if let error = list.error { ErrorNote(text: error) { Task { await list.loadMore() } } }
            } else {
                ProgressView().padding(40)
            }
        }
        .task(id: "\(sort.rawValue)/\(genre?.description ?? "")") {
            let (music, genre) = (services.music, genre)
            let next = Pager<MusicAlbum>(counted: { offset in
                try await music.albums(sort: sort, genreId: genre, offset: offset)
            })
            list = next
            await next.loadMore()
        }
        .task(id: browser.revision) { await list?.refresh() }
        .reloads { await list?.refresh(reporting: true) }
        .selectingAll(.init({ list }, id: \.id))
        .onChange(of: list?.countText) { count = countText(list) }
        .onAppear { count = countText(list) }
    }
}

struct AlbumTile: View {
    @Environment(Browser.self) private var browser
    @Environment(Services.self) private var services
    let album: MusicAlbum
    /// The line under the title; the artist unless the page already says whose albums these are.
    var detail: String?

    var body: some View {
        Button {
            browser.open(.album(album.id))
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                ArtSquare(id: album.id, placeholder: .album)
                VStack(alignment: .leading, spacing: 1) {
                    Text(album.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Text(detail ?? album.artistName).font(.system(size: 11)).foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .contextMenu {
            SelectMenuItem(id: album.id)
            Button("Play", systemImage: "play.fill") { play(shuffled: false) }
            Button("Shuffle", systemImage: "shuffle") { play(shuffled: true) }
            FavoriteMenuItem(id: album.id)
        }
    }

    private func play(shuffled: Bool) {
        Task {
            guard let detail = try? await services.music.album(album.id) else { return }
            await services.player.play(detail.songs, source: album.title, shuffled: shuffled)
        }
    }
}

struct ArtistsList: View {
    @Environment(Services.self) private var services
    @Environment(Browser.self) private var browser
    let genre: Genre.ID?
    @Binding var count: String
    @State private var list: Pager<MusicArtist>?

    var body: some View {
        LazyVStack(spacing: 4) {
            if let list {
                if list.items.isEmpty && list.done { EmptyNote(text: "No artists yet.") }
                ForEach(list.items, id: \.id) { artist in
                    Button {
                        browser.open(.artist(artist.id))
                    } label: {
                        HStack(spacing: 12) {
                            ArtSquare(id: artist.id, round: true, placeholder: .artist).frame(width: 48)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(artist.name).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                                Text(artist.albumCount == 1 ? "1 album" : "\(artist.albumCount) albums")
                                    .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Theme.secondary)
                        }
                        .padding(.vertical, 4)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        SelectMenuItem(id: artist.id)
                        FavoriteMenuItem(id: artist.id)
                    }
                    .selectable(artist.id)
                    .onAppear { if artist.id == list.items.last?.id { Task { await list.loadMore() } } }
                }
                if let error = list.error { ErrorNote(text: error) { Task { await list.loadMore() } } }
            } else {
                ProgressView().padding(40)
            }
        }
        .task(id: genre) {
            let (music, genre) = (services.music, genre)
            let next = Pager<MusicArtist>(counted: { offset in
                try await music.artists(genreId: genre, offset: offset)
            })
            list = next
            await next.loadMore()
            count = countText(list)
        }
        .task(id: browser.revision) { await list?.refresh() }
        .reloads { await list?.refresh(reporting: true) }
        .selectingAll(.init({ list }, id: \.id))
        .onChange(of: list?.countText) { count = countText(list) }
    }
}

struct SongsList: View {
    @Environment(Services.self) private var services
    @Environment(Browser.self) private var browser
    let sort: MusicSongSort
    let genre: Genre.ID?
    @Binding var count: String
    @State private var list: Pager<MusicSong>?
    @State private var target: PlaylistTarget?

    var body: some View {
        LazyVStack(spacing: 2) {
            if let list {
                if list.items.isEmpty && list.done { EmptyNote(text: "No songs yet.") }
                ForEach(Array(list.items.enumerated()), id: \.element.id) { index, song in
                    SongRow(song: song, art: true, target: $target) {
                        Task { await services.player.play(list.items, from: index, source: "Songs") }
                    }
                    .selectable(song.id)
                    .onAppear { if song.id == list.items.last?.id { Task { await list.loadMore() } } }
                }
                if let error = list.error { ErrorNote(text: error) { Task { await list.loadMore() } } }
            } else {
                ProgressView().padding(40)
            }
        }
        .addToPlaylist($target)
        .task(id: "\(sort.rawValue)/\(genre?.description ?? "")") {
            let (music, genre) = (services.music, genre)
            let next = Pager<MusicSong>(counted: { offset in
                try await music.songs(sort: sort, genreId: genre, offset: offset)
            })
            list = next
            await next.loadMore()
            count = countText(list)
        }
        .task(id: browser.revision) { await list?.refresh() }
        .reloads { await list?.refresh(reporting: true) }
        .selectingAll(.init({ list }, id: \.id))
        .onChange(of: list?.countText) { count = countText(list) }
    }
}

struct SongRow: View {
    @Environment(Services.self) private var services
    let song: MusicSong
    var number: Int?
    var art = false
    /// The playlist target the context menu's Add to playlist fills.
    @Binding var target: PlaylistTarget?
    let action: () -> Void

    var body: some View {
        let playing = services.player.current?.id == song.id
        Button(action: action) {
            HStack(spacing: 12) {
                if let number {
                    Text("\(number)").font(.system(size: 15, weight: playing ? .bold : .regular)).monospacedDigit()
                        .foregroundStyle(playing ? Theme.amber : Theme.secondary).frame(width: 28)
                }
                if art {
                    ArtSquare(id: song.albumId, radius: 6, placeholder: .album, badges: StatusBadges(id: song.id))
                        .frame(width: 44)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(song.title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                        .foregroundStyle(playing ? Theme.amber : Theme.primary)
                    if art {
                        Text("\(song.artistName) · \(song.albumTitle)").font(.system(size: 12))
                            .foregroundStyle(Theme.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if let ms = song.durationMs {
                    Text(Format.clock(seconds: Double(ms) / 1000)).font(.system(size: 15)).monospacedDigit()
                        .foregroundStyle(Theme.secondary)
                }
            }
            .padding(.vertical, art ? 3 : 8)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .contextMenu {
            SelectMenuItem(id: song.id)
            FavoriteMenuItem(id: song.id)
            AddToButtons(target: $target, itemIds: [song.id], kind: .music)
            DownloadMenu(.song(song))
        }
    }
}

struct EmptyNote: View {
    let text: String

    var body: some View {
        Text(text).foregroundStyle(Theme.secondary).frame(maxWidth: .infinity).padding(40)
    }
}

struct ErrorNote: View {
    let text: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Text(text).font(.system(size: 13)).foregroundStyle(Theme.error).multilineTextAlignment(.center)
            Button("Try again", action: retry).buttonStyle(SecondaryButtonStyle())
        }
        .padding(20)
    }
}
