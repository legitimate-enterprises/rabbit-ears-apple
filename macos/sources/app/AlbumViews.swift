import RabbitEarsAPI
import RabbitEarsKit
import SwiftUI

struct Heading: View {
    let text: String
    var body: some View { Text(text).font(.system(size: 15, weight: .bold)) }
}

/// Play, Shuffle, Favorite, Add to playlist, Add to station and Download under an album's or artist's name.
struct PlayShuffle: View {
    let itemId: UID
    let download: DownloadTarget
    let play: () -> Void
    let shuffle: () -> Void

    var body: some View {
        // A header column too narrow for one row puts the add and download buttons on a second.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                playing
                adding
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) { playing }
                HStack(spacing: 10) { adding }
            }
        }
    }

    @ViewBuilder private var playing: some View {
        Button(action: play) { Label("Play", systemImage: "play.fill") }.buttonStyle(PrimaryButtonStyle()).fixedSize()
            .needsServer(.play, itemId)
        Button(action: shuffle) { Label("Shuffle", systemImage: "shuffle") }.buttonStyle(SecondaryButtonStyle())
            .fixedSize()
        FavoriteButton(id: itemId)
    }

    @ViewBuilder private var adding: some View {
        PlaylistMenu(itemId: itemId, kind: .music, asButton: true)
        StationMenu(itemId: itemId, kind: .music, asButton: true)
        DownloadButton(target: download)
    }
}

struct AlbumScreen: View {
    @Environment(AppModel.self) private var app
    @Environment(Browser.self) private var browser
    @Environment(MusicPlayer.self) private var player
    let id: UID
    @State private var detail: AlbumDetail?
    @State private var failed = false

    var body: some View {
        Group {
            if let detail {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        header(detail)
                        songs(detail)
                        if !detail.moreByArtist.isEmpty {
                            Heading(text: "More by \(detail.album.artistName)")
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(alignment: .top, spacing: 14) {
                                    ForEach(detail.moreByArtist, id: \.id) {
                                        AlbumTile(album: $0, caption: $0.year.map(String.init)).frame(width: 120)
                                    }
                                }
                            }
                        }
                    }
                    .padding(EdgeInsets(top: 18, leading: 22, bottom: 24, trailing: 22))
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .pageTitle(detail.album.title)
            } else if failed {
                ContentUnavailableView("Not available", systemImage: "questionmark.square.dashed")
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: id) {
            detail = try? await app.musicModel?.album(id)
            failed = detail == nil
        }
    }

    private func header(_ detail: AlbumDetail) -> some View {
        let album = detail.album
        return HStack(alignment: .top, spacing: 24) {
            Art(id: album.id, radius: 10, placeholder: .album).frame(width: 190)
            VStack(alignment: .leading, spacing: 14) {
                Text(album.title).font(.system(size: 26, weight: .bold))
                HStack(spacing: 10) {
                    Button(album.artistName) { browser.open(.artist(album.artistId)) }
                        .buttonStyle(.plain).fontWeight(.semibold).foregroundStyle(Theme.amber)
                    if let year = album.year { Text(String(year)) }
                    Text(Format.songs(album.songCount, durationMs: album.durationMs))
                    if album.lossless { Tag(text: "Lossless") }
                }
                .font(.system(size: 13)).foregroundStyle(Theme.secondary)
                PlayShuffle(
                    itemId: album.id, download: .album(album),
                    play: { Task { await player.play(detail.songs, source: album.title) } },
                    shuffle: { Task { await player.play(detail.songs, source: album.title, shuffled: true) } })
                if let overview = album.overview {
                    Text(overview).font(.system(size: 13)).foregroundStyle(Theme.synopsis)
                        .frame(maxWidth: 560, alignment: .leading)
                }
            }
        }
    }

    private func songs(_ detail: AlbumDetail) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(detail.discs, id: \.self) { disc in
                if detail.discs.count > 1 { Heading(text: "Disc \(disc)").padding(.vertical, 8) }
                ForEach(detail.songs.filter { ($0.discNumber ?? 1) == disc }, id: \.id) { song in
                    SongRow(
                        song: song, queue: detail.songs, index: detail.songs.firstIndex { $0.id == song.id } ?? 0,
                        source: detail.album.title, numbered: true)
                }
            }
        }
    }
}

struct ArtistScreen: View {
    @Environment(AppModel.self) private var app
    @Environment(MusicPlayer.self) private var player
    let id: UID
    @State private var detail: ArtistDetail?
    @State private var failed = false

    var body: some View {
        Group {
            if let detail {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        header(detail.artist)
                        if !detail.popular.isEmpty {
                            Heading(text: "Popular")
                            VStack(spacing: 0) {
                                ForEach(Array(detail.popular.enumerated()), id: \.element.id) { index, song in
                                    SongRow(
                                        song: song, queue: detail.popular, index: index, source: detail.artist.name,
                                        numbered: true, rank: index + 1)
                                }
                            }
                        }
                        Heading(text: "Albums")
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(alignment: .top, spacing: 14) {
                                ForEach(detail.albums, id: \.id) {
                                    AlbumTile(album: $0, caption: $0.year.map(String.init)).frame(width: 120)
                                }
                            }
                        }
                    }
                    .padding(EdgeInsets(top: 18, leading: 22, bottom: 24, trailing: 22))
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .pageTitle(detail.artist.name)
            } else if failed {
                ContentUnavailableView("Not available", systemImage: "questionmark.square.dashed")
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: id) {
            detail = try? await app.musicModel?.artist(id)
            failed = detail == nil
        }
    }

    private func header(_ artist: MusicArtist) -> some View {
        HStack(alignment: .top, spacing: 24) {
            Art(id: artist.id, circle: true, placeholder: .artist).frame(width: 150)
            VStack(alignment: .leading, spacing: 14) {
                Text(artist.name).font(.system(size: 26, weight: .bold))
                HStack(spacing: 10) {
                    Text("\(artist.albumCount) albums")
                    Text("\(artist.songCount) songs")
                    if let genre = artist.genres.first { Text(genre.name) }
                }
                .font(.system(size: 13)).foregroundStyle(Theme.secondary)
                PlayShuffle(
                    itemId: artist.id, download: .artist(artist), play: { play(artist, shuffled: false) },
                    shuffle: { play(artist, shuffled: true) })
                if let overview = artist.overview {
                    Text(overview).font(.system(size: 13)).foregroundStyle(Theme.synopsis)
                        .frame(maxWidth: 560, alignment: .leading)
                }
            }
        }
    }

    private func play(_ artist: MusicArtist, shuffled: Bool) {
        Task {
            guard let songs = try? await app.musicModel?.songs(byArtist: artist.id) else { return }
            await player.play(songs, source: artist.name, shuffled: shuffled)
        }
    }
}
