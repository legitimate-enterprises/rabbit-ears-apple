import RabbitEarsAPI
import RabbitEarsKit
import SwiftUI

/// Apple TV opens and plays playlists and never edits them.
struct PlaylistTiles: View {
    @Environment(PlaylistsModel.self) private var playlists
    let kind: PlaylistKind

    var body: some View {
        let mine = playlists.playlists(kind)
        if mine.isEmpty {
            Text("No playlists yet.").font(.system(size: 30)).foregroundStyle(Theme.secondary)
                .frame(maxWidth: .infinity).padding(80)
        }
        LazyVGrid(columns: GridView.columns, alignment: .leading, spacing: 50) {
            ForEach(mine, id: \.id) { PlaylistTile(playlist: $0) }
        }
        .focusSection()
        .task { await playlists.load() }
    }
}

struct PlaylistTile: View {
    @Environment(Browser.self) private var browser
    let playlist: Playlist

    var body: some View {
        Button {
            browser.open(.playlist(playlist.id))
        } label: {
            VStack(alignment: .leading, spacing: 14) {
                ArtBlock(
                    id: playlist.artItemId ?? playlist.id, aspect: playlist.kind == .music ? 1 : 2 / 3,
                    url: playlist.imageUrl, placeholder: .playlist
                )
                .overlay(alignment: .bottomTrailing) { if playlist.isShared { SharedBadge() } }
                VStack(alignment: .leading, spacing: 2) {
                    Text(playlist.name).font(.system(size: 28, weight: .semibold)).lineLimit(2)
                    Text(PlaylistText.summary(playlist)).font(.system(size: 26)).foregroundStyle(.secondary)
                        .lineLimit(1)
                    if let shared = playlist.sharedBy {
                        Text(shared).font(.system(size: 26)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
        }
        .buttonStyle(CardButtonStyle())
    }
}

/// A show or album is one row, played through the server's play order.
struct PlaylistView: View {
    @Environment(PlaylistsModel.self) private var playlists
    @Environment(Browser.self) private var browser
    @Environment(MusicPlayer.self) private var player
    let id: UID
    @State private var entries: [PlaylistEntry]?

    var body: some View {
        let playlist = playlists.playlists.first { $0.id == id }
        Group {
            if let playlist, let entries {
                HStack(alignment: .top, spacing: 80) {
                    summary(playlist).frame(width: 640, alignment: .leading)
                    ScrollView {
                        VStack(spacing: 8) {
                            ForEach(entries, id: \.id) { entry in
                                row(entry) { start(playlist, from: entry, shuffled: false) }
                            }
                        }
                        .padding(.vertical, 20)
                    }
                    .scrollClipDisabled()
                    .focusSection()
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(EdgeInsets(top: 176, leading: 80, bottom: 60, trailing: 80))
        .background(Theme.ground)
        .ignoresSafeArea()
        .modifier(ChipCorner())
        .toolbar(.hidden, for: .navigationBar)
        .task(id: "\(id)/\(browser.returns)") { entries = await playlists.entries(of: id) ?? [] }
    }

    private func summary(_ playlist: Playlist) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ArtBlock(
                id: playlist.artItemId ?? playlist.id, aspect: playlist.kind == .music ? 1 : 2 / 3, radius: 16,
                url: playlist.imageUrl, placeholder: .playlist
            )
            .overlay(alignment: .bottomTrailing) { if playlist.isShared { SharedBadge() } }
            .frame(width: 440)
            Text(playlist.name).font(.system(size: 72, weight: .bold)).lineLimit(2).minimumScaleFactor(0.6)
                .padding(.top, 28)
            Text(PlaylistText.summary(playlist)).font(.system(size: 30)).foregroundStyle(Theme.secondary)
                .padding(.top, 8)
            if let shared = playlist.sharedBy {
                Text(shared).font(.system(size: 30)).foregroundStyle(Theme.secondary).padding(.top, 4)
            }
            HStack(spacing: 24) {
                Button {
                    start(playlist, from: nil, shuffled: false)
                } label: {
                    Label("Play", systemImage: "play.fill")
                }
                .buttonStyle(TVButtonStyle(primary: true))
                if playlist.kind == .music {
                    Button {
                        start(playlist, from: nil, shuffled: true)
                    } label: {
                        Label("Shuffle", systemImage: "shuffle")
                    }
                    .buttonStyle(TVButtonStyle())
                }
            }
            .padding(.top, 28)
            .focusSection()
        }
    }

    @ViewBuilder
    private func row(_ entry: PlaylistEntry, play: @escaping () -> Void) -> some View {
        if let song = entry.song {
            TrackRow(song: song, number: entry.position + 1, detail: song.artistName, action: play)
        } else {
            Button(action: play) {
                HStack(spacing: 24) {
                    let music = entry.album != nil || entry.artist != nil
                    ArtBlock(
                        id: entry.artId, aspect: music ? 1 : 2 / 3, radius: 8, collection: entry.kind == .collection,
                        placeholder: entry.kind == .collection ? .collection : .playlist
                    )
                    .frame(width: music ? 72 : 56)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(PlaylistText.title(entry)).font(.system(size: 32, weight: .semibold)).lineLimit(1)
                        Text(PlaylistText.detail(entry)).font(.system(size: 26)).foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                }
                .padding(.horizontal, 22).padding(.vertical, 18)
            }
            .buttonStyle(RowButtonStyle(radius: 14, scale: 1.02))
        }
    }

    /// From the top, or from where an entry's rows begin in the play order.
    /// Playing stamps the playlist's last played time.
    private func start(_ playlist: Playlist, from entry: PlaylistEntry?, shuffled: Bool) {
        Task {
            guard let rows = await playlists.playOrder(of: playlist.id) else { return }
            guard let start = entry.map({ rows.start(of: $0.id) }) ?? 0 else { return }
            if playlist.kind == .music {
                await player.play(
                    rows.songs, from: start, source: playlist.name, playlistId: playlist.id, shuffled: shuffled)
            } else if let queue = VideoQueue(rows, start: start, playlistId: playlist.id) {
                browser.play(queue)
            }
        }
    }
}

extension Browser {
    /// Reuses the open cover, as Next episode does; later rows start at the top.
    func play(_ queue: VideoQueue) {
        playing = PlayRequest(
            id: playing?.id ?? UUID(), item: queue.current, editionId: queue.editionId,
            positionMs: playing.map { _ in 0 }, queue: queue)
    }
}

/// The mark on a shared playlist's artwork, alone in its bottom trailing corner.
private struct SharedBadge: View {
    var body: some View {
        Image(systemName: "person.2.fill").font(.system(size: 15, weight: .heavy))
            .foregroundStyle(Theme.amber).frame(width: 36, height: 36)
            .background(.black.opacity(0.6), in: .circle).padding(10)
            .accessibilityLabel("Shared")
    }
}
