import RabbitEarsAPI
import RabbitEarsKit
import SwiftUI

/// An artist: Play and Shuffle, Popular, and the albums.
struct ArtistView: View {
    @Environment(AppModel.self) private var app
    @Environment(MusicPlayer.self) private var player
    let id: Int64
    @State private var detail: ArtistDetail?
    @State private var loaded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 56) {
                if let detail {
                    header(detail)
                    if !detail.albums.isEmpty { albums(detail.albums) }
                } else if loaded {
                    Text("Not available").font(.system(size: 34)).foregroundStyle(Theme.secondary)
                        .frame(maxWidth: .infinity).padding(80)
                } else {
                    ProgressView().frame(maxWidth: .infinity).padding(80)
                }
            }
            .padding(EdgeInsets(top: 176, leading: 80, bottom: 60, trailing: 80))
        }
        .scrollClipDisabled()
        .background(Theme.ground)
        .ignoresSafeArea()
        .modifier(ChipCorner())
        .toolbar(.hidden, for: .navigationBar)
        .task(id: id) {
            detail = try? await app.musicModel?.artist(id)
            loaded = true
        }
    }

    private func header(_ detail: ArtistDetail) -> some View {
        let artist = detail.artist
        return HStack(alignment: .top, spacing: 56) {
            ArtBlock(id: artist.id, radius: 140, placeholder: .artist).frame(width: 280)
            VStack(alignment: .leading, spacing: 0) {
                Text(artist.name).font(.system(size: 100, weight: .bold)).lineLimit(1).minimumScaleFactor(0.5)
                MetaLine(
                    parts: [
                        Format.count(artist.albumCount, "album"),
                        Format.count(artist.songCount, "song"),
                        artist.genres.first?.name ?? "",
                    ]
                )
                .padding(.top, 4)
                HStack(spacing: 24) {
                    Button {
                        play(artist, shuffled: false)
                    } label: {
                        Label("Play", systemImage: "play.fill")
                    }
                    .buttonStyle(TVButtonStyle(primary: true))
                    Button {
                        play(artist, shuffled: true)
                    } label: {
                        Label("Shuffle", systemImage: "shuffle")
                    }
                    .buttonStyle(TVButtonStyle())
                }
                .padding(.top, 28)
                .focusSection()
                if let overview = artist.overview {
                    Text(overview).font(.system(size: 28)).foregroundStyle(Theme.synopsis).lineLimit(4).padding(
                        .top, 28)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if !detail.popular.isEmpty { popular(detail) }
        }
    }

    private func popular(_ detail: ArtistDetail) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Popular").font(.system(size: 34, weight: .bold)).padding(.bottom, 8)
            ForEach(Array(detail.popular.enumerated()), id: \.element.id) { index, song in
                TrackRow(song: song, number: index + 1) {
                    Task { await player.play(detail.popular, from: index, source: detail.artist.name) }
                }
            }
        }
        .frame(width: 700)
        .focusSection()
    }

    private func albums(_ albums: [MusicAlbum]) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Albums").font(.system(size: 34, weight: .bold))
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 40) {
                    ForEach(albums, id: \.id) { album in
                        AlbumTile(album: album, caption: album.year.map(String.init)).frame(width: 220)
                    }
                }
                .padding(.vertical, 20)
            }
            .scrollClipDisabled()
        }
        .focusSection()
    }

    private func play(_ artist: MusicArtist, shuffled: Bool) {
        Task {
            guard let songs = try? await app.musicModel?.songs(byArtist: artist.id) else { return }
            await player.play(songs, source: artist.name, shuffled: shuffled)
        }
    }
}

/// An album: the cover and Play on the left, its songs by disc and track on the right.
struct AlbumView: View {
    @Environment(AppModel.self) private var app
    @Environment(Browser.self) private var browser
    @Environment(MusicPlayer.self) private var player
    let id: Int64
    @State private var detail: AlbumDetail?
    @State private var loaded = false

    var body: some View {
        Group {
            if let detail {
                HStack(alignment: .top, spacing: 80) {
                    summary(detail).frame(width: 640, alignment: .leading)
                    ScrollView {
                        songs(detail).padding(.vertical, 20)
                    }
                    .scrollClipDisabled()
                    .focusSection()
                }
            } else if loaded {
                Text("Not available").font(.system(size: 34)).foregroundStyle(Theme.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(EdgeInsets(top: 176, leading: 80, bottom: 60, trailing: 80))
        .background(Theme.ground)
        .ignoresSafeArea()
        .modifier(ChipCorner())
        .toolbar(.hidden, for: .navigationBar)
        .task(id: id) {
            detail = try? await app.musicModel?.album(id)
            loaded = true
        }
    }

    private func summary(_ detail: AlbumDetail) -> some View {
        let album = detail.album
        return VStack(alignment: .leading, spacing: 0) {
            ArtBlock(id: album.id, radius: 16, placeholder: .album).frame(width: 440)
            Text(album.title).font(.system(size: 72, weight: .bold)).lineLimit(2).minimumScaleFactor(0.6)
                .padding(.top, 28)
            HStack(spacing: 22) {
                Text(album.artistName).foregroundStyle(Theme.amber)
                if let year = album.year { Text(String(year)) }
                Text(Format.songs(album.songCount, durationMs: album.durationMs)).foregroundStyle(Theme.secondary)
                if album.lossless { Tag(text: "Lossless") }
            }
            .font(.system(size: 30))
            .lineLimit(1)
            .padding(.top, 8)
            HStack(spacing: 24) {
                Button {
                    Task { await player.play(detail.songs, source: album.title) }
                } label: {
                    Label("Play", systemImage: "play.fill")
                }
                .buttonStyle(TVButtonStyle(primary: true))
                Button {
                    Task { await player.play(detail.songs, source: album.title, shuffled: true) }
                } label: {
                    Label("Shuffle", systemImage: "shuffle")
                }
                .buttonStyle(TVButtonStyle())
            }
            .padding(.top, 28)
            .focusSection()
            if let overview = album.overview {
                Text(overview).font(.system(size: 28)).foregroundStyle(Theme.synopsis).lineLimit(3).padding(.top, 28)
            }
        }
    }

    private func songs(_ detail: AlbumDetail) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(detail.songs.enumerated()), id: \.element.id) { index, song in
                if detail.discs.count > 1, index == 0 || song.discNumber != detail.songs[index - 1].discNumber {
                    Text("Disc \(song.discNumber ?? 1)").font(.system(size: 30, weight: .bold))
                        .foregroundStyle(Theme.secondary).padding(.horizontal, 22).padding(.top, index == 0 ? 0 : 24)
                }
                TrackRow(song: song, number: song.trackNumber ?? index + 1) {
                    Task { await player.play(detail.songs, from: index, source: detail.album.title) }
                }
            }
        }
    }
}
