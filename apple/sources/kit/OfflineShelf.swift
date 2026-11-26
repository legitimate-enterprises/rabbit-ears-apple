import Foundation
import RabbitEarsAPI

/// A collection as it was when last seen, with its movies in release order.
struct StoredCollection: Codable, Sendable {
    var collection: MovieCollection
    var movieIds: [Int64]
}

/// A playlist as it was when last seen: its entries and its play order.
struct StoredPlaylist: Codable, Sendable {
    var playlist: Playlist
    var entries: [PlaylistEntry]
    var rows: [PlayOrderRow]
}

/// The server's own description of what is downloaded, as its answers
/// gave it, so the existing screens can be answered without the server.
struct OfflineShelf: Codable, Sendable {
    /// The last Me the server answered, which the app opens with offline.
    var me: Components.Schemas.Me?
    var libraries: [Library] = []
    /// Movies and episodes with their seasons and shows.
    var items: [Int64: Item] = [:]
    var watch: [Int64: [Int64: WatchState]] = [:]
    var songs: [Int64: MusicSong] = [:]
    var albums: [Int64: MusicAlbum] = [:]
    var artists: [Int64: MusicArtist] = [:]
    var videos: [Int64: YouTubeVideo] = [:]
    var channels: [Int64: YouTubeChannel] = [:]
    var collections: [Int64: StoredCollection] = [:]
    var playlists: [Int64: StoredPlaylist] = [:]
    /// Artwork file names kept, by the key `ArtKey` makes.
    var art: Set<String> = []

    /// The item and every parent above it, the title first.
    func lineage(_ id: Int64) -> [Item] {
        var chain: [Item] = []
        var next = items[id]
        while let item = next, !chain.contains(where: { $0.id == item.id }) {
            chain.append(item)
            next = item.parentId.flatMap { items[$0] }
        }
        return chain
    }

    /// Forgets what no kept title, collection or playlist needs, and
    /// answers the artwork files still wanted.
    mutating func prune(titles: Set<Int64>, collections: Set<Int64>, playlists: Set<Int64>) -> Set<String> {
        let lines = Set(titles.flatMap { lineage($0).map(\.id) })
        items = items.filter { lines.contains($0.key) }
        songs = songs.filter { titles.contains($0.key) }
        videos = videos.filter { titles.contains($0.key) }
        let albumIds = Set(songs.values.map(\.albumId))
        let artistIds = Set(songs.values.flatMap { [$0.artistId, $0.albumArtistId] })
        albums = albums.filter { albumIds.contains($0.key) }
        artists = artists.filter { artistIds.contains($0.key) }
        channels = channels.filter { Set(videos.values.map(\.channelId)).contains($0.key) }
        self.collections = self.collections.filter { collections.contains($0.key) }
        self.playlists = self.playlists.filter { playlists.contains($0.key) }
        let owners =
            lines.union(titles).union(albumIds).union(artistIds).union(channels.keys)
            .union(self.playlists.values.compactMap(\.playlist.artItemId))
        art = art.filter { key in
            guard let parsed = ArtKey(file: key) else { return false }
            return parsed.collection ? self.collections[parsed.id] != nil : owners.contains(parsed.id)
        }
        return art
    }
}

/// An artwork file's name: `item-12-poster` or `collection-3-backdrop`.
struct ArtKey: Equatable {
    let id: Int64
    let kind: ArtworkStore.Kind
    let collection: Bool

    init(id: Int64, kind: ArtworkStore.Kind, collection: Bool = false) {
        self.id = id
        self.kind = kind
        self.collection = collection
    }

    init?(file: String) {
        let parts = file.split(separator: "-")
        guard parts.count == 3, let id = Int64(parts[1]), let kind = ArtworkStore.Kind(rawValue: String(parts[2]))
        else { return nil }
        self.init(id: id, kind: kind, collection: parts[0] == "collection")
    }

    var file: String { "\(collection ? "collection" : "item")-\(id)-\(kind.rawValue)" }
}
