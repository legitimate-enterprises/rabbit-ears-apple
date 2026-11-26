import Foundation
import OpenAPIRuntime
import RabbitEarsAPI

extension DownloadStore {
    /// What downloading the target at a quality would keep, as the server
    /// resolves it now for this device and profile.
    public func plan(_ target: DownloadTarget, quality: DownloadQuality, profile: Int64) async throws -> DownloadPlan {
        guard let link else { throw AppError.signedOut }
        let titles: [DownloadTitle]
        do {
            titles = try await resolve(target, quality: quality, profile: profile, link)
        } catch {
            throw AppError.from(error, unauthorized: .signedOut)
        }
        let settings = settings(profile)
        let kept = titles.filter { title in
            title.available
                && !(target.standing && title.watched && !settings.keeps(library: title.libraryId, kind: title.kind))
        }
        return DownloadPlan(profileId: profile, target: target, quality: quality, titles: kept)
    }

    /// Plans and keeps a request in one go, unless it is big enough to ask about first; then the plan is answered.
    public func request(
        _ target: DownloadTarget, quality: DownloadQuality, profile: Int64
    ) async throws -> DownloadPlan? {
        let plan = try await plan(target, quality: quality, profile: profile)
        if needsConfirmation(plan) { return plan }
        keep(plan)
        return nil
    }

    private func resolve(
        _ target: DownloadTarget, quality: DownloadQuality, profile: Int64, _ link: Link
    ) async throws -> [DownloadTitle] {
        let snapshot = await link.endpoint.snapshot(facts(), checkedWith: link.client, maxBitrate: nil)
        return try await link.client.resolveDownloads(
            path: .init(profileId: profile),
            body: .json(.init(targets: [target.input], quality: quality, snapshot: snapshot))
        ).ok.body.json.titles
    }

    /// While online with the profile active: sends its offline watch
    /// changes, drops what it may no longer keep, brings each standing
    /// request up to date, and fetches what is new. A profile the server
    /// no longer knows loses its downloads, and a device it no longer
    /// knows loses all of them. What already waits is fetched whether or not
    /// the rest went through.
    public func sync(profile: Int64) async {
        guard let link else { return }
        if await flushWatch(profile: profile, link) { await refresh(profile: profile, link) }
        await pump()
    }

    private func refresh(profile: Int64, _ link: Link) async {
        let held = Array(Set(requests(for: profile).flatMap(\.titles))).sorted()
        do {
            if !held.isEmpty {
                for chunk in stride(from: 0, to: held.count, by: 5000) {
                    let ids = Array(held[chunk..<min(chunk + 5000, held.count)])
                    let answer = try await link.client.syncDownloads(
                        path: .init(profileId: profile), body: .json(.init(itemIds: ids))
                    ).ok.body.json
                    drop(Set(answer.remove), profile: profile)
                }
            }
            for request in requests(for: profile) where request.target.standing {
                do {
                    let titles = try await resolve(request.target, quality: request.quality, profile: profile, link)
                    apply(titles, to: request.target, profile: profile, quality: request.quality)
                    await describe(request.target, profile: profile, link)
                } catch {
                    guard APIError.from(error)?.code == .notFound else { throw error }
                    remove(request.target, profile: profile)
                }
            }
        } catch {
            return lost(error, profile: profile)
        }
        for (id, title) in ledger.titles {
            if case .failed = title.state { ledger.titles[id]?.state = .pending }
        }
        save()
    }

    /// The server's unauthorized is a device it no longer knows, its not_found such a profile.
    private func lost(_ error: any Error, profile: Int64) {
        guard let api = APIError.from(error) else { return }
        if api.code == .unauthorized {
            wipe()
        } else if api.code == .notFound {
            wipe(profile: profile)
        }
    }

    /// Sends the profile's offline watch changes oldest first, each with
    /// when it happened, so the server keeps whichever change is newer.
    /// False while a change is left to send.
    func flushWatch(profile: Int64, _ link: Link) async -> Bool {
        let changes = unsynced(profile).sorted { $0.value.at < $1.value.at }
        for (itemId, change) in changes {
            do {
                let state = try await link.client.putWatchState(
                    path: .init(profileId: profile, itemId: itemId),
                    body: .json(
                        .init(
                            watched: change.watched, positionMs: change.positionMs, editionId: change.editionId,
                            at: change.at))
                ).ok.body.json
                ledger.shelf.watch[profile, default: [:]][itemId] = state
                ledger.unsynced[profile]?[itemId] = nil
            } catch {
                guard let api = APIError.from(error) else { return false }
                if api.code == .unauthorized {
                    wipe()
                    return false
                }
                // The title, its edition or the profile went, or the change
                // is one the server never takes; anything else, as a proxy's
                // 404, is tried again.
                guard api.status == 400 || api.code == .notFound else { return false }
                ledger.unsynced[profile]?[itemId] = nil
            }
        }
        save()
        return true
    }

    /// Keeps what a collection or playlist screen shows of it, with its art.
    func describe(_ target: DownloadTarget, profile: Int64, _ link: Link) async {
        let client = link.client
        switch target.scope {
        case .item: return
        case .collection:
            guard let collection = try? await client.getCollection(path: .init(collectionId: target.id)).ok.body.json
            else { return }
            let movies: [Item] =
                (try? await allPages { offset in
                    let page = try await client.listCollectionMovies(
                        path: .init(collectionId: target.id), query: .init(limit: 200, offset: offset)
                    ).ok.body.json
                    return (page.items, page.nextOffset)
                }) ?? []
            ledger.shelf.collections[target.id] = StoredCollection(collection: collection, movieIds: movies.map(\.id))
            for kind in [ArtworkStore.Kind.poster, .backdrop] {
                await keepArt(ArtKey(id: target.id, kind: kind, collection: true), client)
            }
        case .playlist:
            let path = Operations.GetPlaylist.Input.Path(profileId: profile, playlistId: target.id)
            guard let playlist = try? await client.getPlaylist(path: path).ok.body.json else { return }
            let entries: [PlaylistEntry] =
                (try? await allPages { offset in
                    let page = try await client.listPlaylistEntries(
                        path: .init(profileId: profile, playlistId: target.id),
                        query: .init(limit: 200, offset: offset)
                    ).ok.body.json
                    return (page.items, page.nextOffset)
                }) ?? []
            let rows: [PlayOrderRow] =
                (try? await allPages { offset in
                    let page = try await client.listPlaylistPlayOrder(
                        path: .init(profileId: profile, playlistId: target.id),
                        query: .init(limit: 200, offset: offset)
                    ).ok.body.json
                    return (page.items, page.nextOffset)
                }) ?? []
            ledger.shelf.playlists[target.id] = StoredPlaylist(playlist: playlist, entries: entries, rows: rows)
            if let art = playlist.artItemId { await keepArt(ArtKey(id: art, kind: .poster), client) }
        }
        save()
    }

    // MARK: Metadata

    /// Keeps what the screens show of a title, with its parents and their
    /// artwork; whatever the server does not answer is left out.
    func describe(_ title: StoredTitle, _ link: Link) async {
        let client = link.client
        var art: [ArtKey] = []
        switch title.kind {
        case .movie, .episode:
            var next: Int64? = title.itemId
            while let id = next, let item = try? await client.getItem(path: .init(itemId: id)).ok.body.json {
                ledger.shelf.items[id] = item
                art += [ArtKey(id: id, kind: .poster), ArtKey(id: id, kind: .backdrop)]
                next = item.parentId
            }
        case .song:
            art += await describeSong(title.itemId, client)
        case .video:
            guard let video = try? await client.getYouTubeVideo(path: .init(videoId: title.itemId)).ok.body.json
            else { break }
            ledger.shelf.videos[video.id] = video
            if let channel = try? await client.getYouTubeChannel(path: .init(channelId: video.channelId)).ok.body
                .json
            {
                ledger.shelf.channels[channel.id] = channel
            }
            art += [ArtKey(id: video.id, kind: .poster), ArtKey(id: video.channelId, kind: .poster)]
        }
        for key in art { await keepArt(key, client) }
    }

    /// A song with its album and artists; the artwork to keep for it.
    private func describeSong(_ id: Int64, _ client: Client) async -> [ArtKey] {
        guard let song = try? await client.getMusicSong(path: .init(songId: id)).ok.body.json else {
            return []
        }
        ledger.shelf.songs[song.id] = song
        if let album = try? await client.getMusicAlbum(path: .init(albumId: song.albumId)).ok.body.json {
            ledger.shelf.albums[album.id] = album
        }
        for id in Set([song.artistId, song.albumArtistId]) {
            if let artist = try? await client.getMusicArtist(path: .init(artistId: id)).ok.body.json {
                ledger.shelf.artists[id] = artist
            }
        }
        return [song.albumId, song.artistId, song.albumArtistId].map { ArtKey(id: $0, kind: .poster) }
    }

    /// One artwork file, fetched once.
    func keepArt(_ key: ArtKey, _ client: Client) async {
        guard !ledger.shelf.art.contains(key.file) else { return }
        let body: HTTPBody?
        if key.collection {
            body = try? await client.getCollectionArtwork(
                path: .init(collectionId: key.id, kind: key.kind == .poster ? .poster : .backdrop)
            ).ok.body.image_Ast_
        } else {
            body = try? await client.getItemArtwork(
                path: .init(itemId: key.id, kind: key.kind == .poster ? .poster : .backdrop)
            ).ok.body.image_Ast_
        }
        guard let body, let data = try? await Data(collecting: body, upTo: 16 << 20) else { return }
        try? FileManager.default.createDirectory(at: art, withIntermediateDirectories: true)
        guard (try? data.write(to: art.appending(path: key.file), options: .atomic)) != nil else { return }
        ledger.shelf.art.insert(key.file)
    }
}
