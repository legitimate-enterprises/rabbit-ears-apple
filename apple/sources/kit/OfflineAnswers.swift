import Foundation
import RabbitEarsAPI

/// Everything on the device fits the first page, so a later page is empty and the total is the whole list's.
private struct Page<T: Encodable>: Encodable {
    let items: [T]
    let total: Int

    init(_ all: [T], first: Bool = true) {
        items = first ? all : []
        total = all.count
    }
}

extension DownloadStore {
    /// The profile the server last had active here, which answers for the calls that name none.
    var activeProfile: Int64 { ledger.shelf.me?.activeProfileId ?? 0 }

    /// The titles on the device that the profile's own requests cover.
    func visible(_ profile: Int64) -> Set<Int64> {
        Set(requests(for: profile).flatMap(\.titles).filter { ledger.titles[$0]?.state == .onDevice })
    }

    /// A watch-state page the server last answered, with the profile's changes it has not had yet.
    func withUnsynced(_ call: LocalCall, _ answer: Data) -> Data {
        let profile = call.id(after: "profiles") ?? activeProfile
        let mine = (ledger.shelf.watch[profile] ?? [:]).filter { ledger.unsynced[profile]?[$0.key] != nil }
        guard call.operation == "listWatchStates", !mine.isEmpty,
            var page = try? Self.decoder.decode(Components.Schemas.WatchStatePage.self, from: answer)
        else { return answer }
        page.items.removeAll { mine[$0.itemId] != nil }
        if (call.number("offset") ?? 0) == 0 { page.items += mine.values }
        return (try? Self.encoder.encode(page)) ?? answer
    }

    /// The server's answer as the downloads give it; nil for what the
    /// store cannot answer, which then fails as the server not answering.
    func offline(_ call: LocalCall) -> LocalAnswer? {
        guard hasDownloads else { return nil }
        if let answer = me(call) ?? catalog(call) ?? artAndSearch(call) ?? music(call) ?? youtube(call) ?? lists(call) {
            return answer
        }
        switch call.operation {
        case "getUpNext": return upNext(call)
        case "listMusicLetters": return letters(call)
        case "listPlaybackSessions", "listWatchTogethers", "listStations", "listGenres", "listRecentlyPlayedMusic",
            "listActiveOccasions":
            return .json(Page<Int>([]))
        default: return nil
        }
    }

    /// Opens the app as it was last signed in, once something is downloaded.
    /// A profile with a PIN unlocks offline only while it was the one
    /// unlocked here when the server was last reached.
    private func me(_ call: LocalCall) -> LocalAnswer? {
        guard let me = ledger.shelf.me else { return nil }
        switch call.operation {
        case "getMe": return .json(me)
        case "lockDevice":
            ledger.shelf.me?.locked = true
            return .noContent
        case "unlockProfile":
            guard let id = call.id(after: "profiles"),
                let profile = me.profiles.first(where: { $0.id == id }) ?? (me.account.id == id ? me.account : nil)
            else { return .notFound }
            let pin = call.decode(Components.Schemas.UnlockRequest.self)?.pin
            let stillUnlocked = pin == nil && me.locked != true && me.activeProfileId == id
            guard !profile.hasPin || stillUnlocked else { return nil }
            ledger.shelf.me?.activeProfileId = id
            ledger.shelf.me?.locked = false
            return .noContent
        default: return nil
        }
    }

    private func catalog(_ call: LocalCall) -> LocalAnswer? {
        let shelf = ledger.shelf
        let profile = call.id(after: "profiles") ?? activeProfile
        let shown = visible(profile)
        let lines = Set(shown.flatMap { shelf.lineage($0).map(\.id) })
        let watch = (shelf.watch[profile] ?? [:]).filter { shown.contains($0.key) }
        switch call.operation {
        case "listItems":
            guard call.query["personId"] == nil, (call.number("offset") ?? 0) == 0 else {
                return .json(Page<Item>([]))
            }
            let kind = call.query["kind"]
            return .json(
                Page(lines.compactMap { shelf.items[$0] }.filter { kind == nil || $0.kind.rawValue == kind }))
        case "getItem":
            return call.id(after: "items").flatMap { lines.contains($0) ? shelf.items[$0] : nil }.map { .json($0) }
                ?? .notFound
        case "listWatchStates":
            return .json(Page(Array(watch.values), first: (call.number("offset") ?? 0) == 0))
        case "getWatchState":
            return call.id(after: "watch-state").flatMap { watch[$0] }.map { .json($0) } ?? .notFound
        case "putWatchState":
            guard let id = call.id(after: "watch-state"),
                let input = call.decode(Components.Schemas.WatchStateInput.self)
            else { return .notFound }
            record(
                watched: input.watched, positionMs: input.watched ? 0 : input.positionMs ?? 0,
                editionId: input.editionId, itemId: id, profile: profile)
            return ledger.shelf.watch[profile]?[id].map { .json($0) } ?? .notFound
        case "putWatchStates": return markMany(call, profile: profile, shown: shown)
        default: return nil
        }
    }

    /// Marks each title named, or under a show, season or channel named, as a batch does.
    private func markMany(_ call: LocalCall, profile: Int64, shown: Set<Int64>) -> LocalAnswer {
        let shelf = ledger.shelf
        guard let input = call.decode(Components.Schemas.WatchStateBatchInput.self) else { return .notFound }
        let named = Set(input.itemIds)
        let channel = { (id: Int64) in shelf.videos[id].map { named.contains($0.channelId) } ?? false }
        for id in shown
        where named.contains(id) || channel(id) || shelf.lineage(id).contains(where: { named.contains($0.id) }) {
            record(watched: input.watched, positionMs: 0, itemId: id, profile: profile)
        }
        return .noContent
    }

    private func artAndSearch(_ call: LocalCall) -> LocalAnswer? {
        let shelf = ledger.shelf
        let profile = activeProfile
        let shown = visible(profile)
        let lines = Set(shown.flatMap { shelf.lineage($0).map(\.id) })
        switch call.operation {
        case "getItemArtwork", "getCollectionArtwork":
            let collection = call.operation == "getCollectionArtwork"
            guard let id = call.id(after: collection ? "collections" : "items"),
                let kind = call.segments.last.flatMap(ArtworkStore.Kind.init(rawValue:))
            else { return .notFound }
            let key = ArtKey(id: id, kind: kind, collection: collection).file
            guard shelf.art.contains(key), let data = try? Data(contentsOf: art.appending(path: key)) else {
                return .notFound
            }
            return LocalAnswer(status: 200, body: data, contentType: "image/jpeg")
        case "search":
            let words = (call.query["q"] ?? "").lowercased()
            let items = lines.compactMap { shelf.items[$0] }.filter { Catalog.title($0).lowercased().contains(words) }
            let songs = shelf.songs.values.filter { shown.contains($0.id) && $0.title.lowercased().contains(words) }
            let videos = shelf.videos.values.filter { shown.contains($0.id) && $0.title.lowercased().contains(words) }
            return .json(
                SearchResult(
                    movies: items.filter { $0.kind == .movie }, shows: items.filter { $0.kind == .show },
                    episodes: items.filter { $0.kind == .episode }, people: [], artists: [], albums: [],
                    songs: Array(songs), channels: [], videos: videos.map { watched($0, profile) }))
        case "searchMusic":
            let words = (call.query["q"] ?? "").lowercased()
            let songs = shelf.songs.values.filter { shown.contains($0.id) }
            return .json(
                MusicSearchResult(
                    artists: Set(songs.flatMap { [$0.artistId, $0.albumArtistId] }).compactMap { shelf.artists[$0] }
                        .filter { $0.name.lowercased().contains(words) },
                    albums: Set(songs.map(\.albumId)).compactMap { shelf.albums[$0] }
                        .filter { $0.title.lowercased().contains(words) },
                    songs: songs.filter { $0.title.lowercased().contains(words) }))
        default: return nil
        }
    }

    private func music(_ call: LocalCall) -> LocalAnswer? {
        let shelf = ledger.shelf
        let shown = visible(activeProfile)
        let songs = shelf.songs.values.filter { shown.contains($0.id) }
        let albumIds = Set(songs.map(\.albumId))
        let artistIds = Set(songs.flatMap { [$0.artistId, $0.albumArtistId] })
        let artist = call.number("artistId")
        let first = (call.number("offset") ?? 0) == 0
        let letter = call.query["letter"]
        switch call.operation {
        case "listMusicSongs":
            let picked = songs.filter { song in
                (call.number("albumId").map { $0 == song.albumId } ?? true)
                    && (artist.map { $0 == song.artistId || $0 == song.albumArtistId } ?? true)
            }
            let sorted =
                call.query["sort"] == "title" || call.query["sort"] == nil && call.number("albumId") == nil
                ? picked.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
                : picked.sorted {
                    ($0.albumTitle, $0.discNumber ?? 1, $0.trackNumber ?? 0)
                        < ($1.albumTitle, $1.discNumber ?? 1, $1.trackNumber ?? 0)
                }
            return .json(Page(sorted, first: first))
        case "listMusicAlbums":
            let albums = albumIds.compactMap { shelf.albums[$0] }.filter {
                (artist == nil || $0.artistId == artist) && (letter == nil || Self.letter($0.title) == letter)
            }
            let sorted: [MusicAlbum] =
                switch call.query["sort"] {
                case "added": albums.sorted { $0.addedAt > $1.addedAt }
                case "year": albums.sorted { ($0.year ?? 0) > ($1.year ?? 0) }
                default: albums.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
                }
            return .json(Page(sorted, first: first))
        case "listMusicArtists":
            let artists = artistIds.compactMap { shelf.artists[$0] }
                .filter { letter == nil || Self.letter($0.sortName) == letter }
                .sorted { $0.sortName.localizedStandardCompare($1.sortName) == .orderedAscending }
            return .json(Page(artists, first: first))
        case "getMusicSong":
            return call.id(after: "songs").flatMap { shown.contains($0) ? shelf.songs[$0] : nil }.map { .json($0) }
                ?? .notFound
        case "getMusicAlbum":
            return call.id(after: "albums").flatMap { albumIds.contains($0) ? shelf.albums[$0] : nil }
                .map { .json($0) } ?? .notFound
        case "getMusicArtist":
            return call.id(after: "artists").flatMap { artistIds.contains($0) ? shelf.artists[$0] : nil }
                .map { .json($0) } ?? .notFound
        default: return nil
        }
    }

    /// How many downloaded albums or artists file under each letter, A to Z, then #, as the server orders them.
    private func letters(_ call: LocalCall) -> LocalAnswer {
        let shelf = ledger.shelf
        let shown = visible(activeProfile)
        let songs = shelf.songs.values.filter { shown.contains($0.id) }
        let names =
            call.query["of"] == Components.Schemas.MusicLetterGroup.artists.rawValue
            ? Set(songs.flatMap { [$0.artistId, $0.albumArtistId] }).compactMap { shelf.artists[$0]?.sortName }
            : Set(songs.map(\.albumId)).compactMap { shelf.albums[$0]?.title }
        let filed: [String: [String]] = Dictionary(grouping: names, by: Self.letter)
        let letters = filed.keys.sorted { ($0 == "#" ? "~" : $0) < ($1 == "#" ? "~" : $1) }
        let items = letters.map { Components.Schemas.MusicLetterCount(letter: $0, count: filed[$0]?.count ?? 0) }
        return .json(Components.Schemas.MusicLetterCountList(items: items))
    }

    /// The letter the server files a name under: its first character, A to Z, else #.
    nonisolated static func letter(_ name: String) -> String {
        guard let first = name.unicodeScalars.first, ("A"..."Z").contains(first) || ("a"..."z").contains(first) else {
            return "#"
        }
        return String(first).uppercased()
    }

    private func youtube(_ call: LocalCall) -> LocalAnswer? {
        let shelf = ledger.shelf
        let profile = activeProfile
        let shown = visible(profile)
        let videos = shelf.videos.values.filter { shown.contains($0.id) }.map { watched($0, profile) }
        let channelIds = Set(videos.map(\.channelId))
        let first = (call.number("offset") ?? 0) == 0
        switch call.operation {
        case "listYouTubeVideos":
            let picked = videos.filter { video in
                (call.number("channelId").map { $0 == video.channelId } ?? true)
                    && (call.query["inProgress"] != "true" || video.positionMs > 0)
            }
            let sorted =
                call.query["sort"] == "oldest"
                ? picked.sorted { ($0.publishedOn ?? "") < ($1.publishedOn ?? "") }
                : picked.sorted { ($0.publishedOn ?? "") > ($1.publishedOn ?? "") }
            return .json(Page(sorted, first: first))
        case "listYouTubeChannels":
            let channels = channelIds.compactMap { shelf.channels[$0] }
                .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            return .json(Page(channels, first: first))
        case "getYouTubeVideo":
            return call.id(after: "videos").flatMap { id in videos.first { $0.id == id } }.map { .json($0) }
                ?? .notFound
        case "getYouTubeChannel":
            return call.id(after: "channels").flatMap { channelIds.contains($0) ? shelf.channels[$0] : nil }
                .map { .json($0) } ?? .notFound
        default: return nil
        }
    }

    /// The profile's own downloaded collections and playlists, each holding only what is on the device.
    private func lists(_ call: LocalCall) -> LocalAnswer? {
        let shelf = ledger.shelf
        let profile = call.id(after: "profiles") ?? activeProfile
        let shown = visible(profile)
        let mine = requests(for: profile)
        let collections = mine.filter { $0.target.scope == .collection }.compactMap { shelf.collections[$0.target.id] }
            .filter { $0.movieIds.contains(where: shown.contains) }
        let playlists = mine.filter { $0.target.scope == .playlist }.compactMap { shelf.playlists[$0.target.id] }
        let first = (call.number("offset") ?? 0) == 0
        switch call.operation {
        case "listCollections": return .json(Page(collections.map(\.collection), first: first))
        case "getCollection":
            return call.id(after: "collections").flatMap { id in collections.first { $0.collection.id == id } }
                .map { .json($0.collection) } ?? .notFound
        case "listCollectionMovies":
            let movies = call.id(after: "collections").flatMap { id in collections.first { $0.collection.id == id } }
                .map { $0.movieIds.filter(shown.contains).compactMap { shelf.items[$0] } }
            return movies.map { .json(Page($0, first: first)) } ?? .notFound
        case "listPlaylists":
            let kind = call.query["kind"]
            return .json(
                Page(playlists.map(\.playlist).filter { kind == nil || $0.kind.rawValue == kind }, first: first))
        case "getPlaylist", "listPlaylistEntries", "listPlaylistPlayOrder":
            guard let id = call.id(after: "playlists"), let stored = playlists.first(where: { $0.playlist.id == id })
            else { return .notFound }
            let rows = stored.rows.filter { shown.contains($0.itemId) }
            switch call.operation {
            case "getPlaylist": return .json(stored.playlist)
            case "listPlaylistEntries":
                let entries = Set(rows.map(\.entryId))
                return .json(Page(stored.entries.filter { entries.contains($0.id) }, first: first))
            default: return .json(Page(rows, first: first))
            }
        default: return nil
        }
    }

    /// A video as the profile last left it, offline changes included.
    private func watched(_ video: YouTubeVideo, _ profile: Int64) -> YouTubeVideo {
        guard let state = ledger.shelf.watch[profile]?[video.id] else { return video }
        var video = video
        video.watched = state.watched
        video.positionMs = state.positionMs
        video.lastPlayedAt = state.lastPlayedAt
        return video
    }
}
