import Foundation
import GRDB
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

    /// While online with the profile active: drops what it may no longer
    /// keep, brings each standing request up to date, and fetches what is
    /// new. A profile the server no longer knows loses its downloads, and a
    /// device it no longer knows loses all of them. What already waits is
    /// fetched whether or not the rest went through.
    public func sync(profile: Int64) async {
        guard let link else { return }
        forgetProfilesGone()
        await refresh(profile: profile, link)
        await pump()
    }

    /// Only the owner's Me lists pending adults, so only it names every profile the household has.
    private func forgetProfilesGone() {
        guard let me, me.household?.adultId == me.activeProfileId else { return }
        let known = Set(ledger.requests.map(\.profileId)).union(ledger.settings.keys)
        for profile in known.subtracting(me.profiles.map(\.id)) { wipe(profile: profile) }
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

    /// Keeps the artwork a collection or playlist shows with; a playlist's
    /// is its art title's, as the replica reads it to the profile.
    func describe(_ target: DownloadTarget, profile: Int64, _ link: Link) async {
        let client = link.client
        var keys: [ArtKey] = []
        switch target.scope {
        case .item: return
        case .collection: keys = [.poster, .backdrop].map { ArtKey(id: target.id, kind: $0, collection: true) }
        case .playlist:
            guard
                let art = try? await replica?.read({ db in
                    try PlaylistRows.playlist(db, profile: profile, id: target.id)?.artItemId
                }) ?? nil
            else { return }
            keys = [ArtKey(id: art, kind: .poster)]
        }
        for key in keys { await keepArt(key, client) }
        if let index = ledger.requests.firstIndex(where: { $0.profileId == profile && $0.target == target }) {
            ledger.requests[index].art = keys.map(\.file)
        }
        save()
    }

    // MARK: Artwork

    /// Keeps the artwork a title shows with, its parents' included, as the
    /// replica holds them; whatever the server does not answer is left out.
    func describe(_ title: StoredTitle, _ link: Link) async {
        let (id, kind) = (title.itemId, title.kind)
        let art = (try? await replica?.read { db in try Self.art(of: id, kind, db) }) ?? []
        for key in art { await keepArt(key, link.client) }
        ledger.titles[title.itemId]?.art = art.map(\.file)
    }

    /// A movie or episode and each item above it, both images; a song's
    /// album, performer and album artist; a video and its channel.
    private nonisolated static func art(
        of id: Int64, _ kind: DownloadTitle.KindPayload, _ db: Database
    ) throws -> [ArtKey] {
        switch kind {
        case .movie, .episode:
            var art: [ArtKey] = []
            var next: Int64? = id
            while let current = next,
                let row = try Row.fetchOne(db, sql: "SELECT parent_id FROM item WHERE id = ?", arguments: [current])
            {
                art += [ArtKey(id: current, kind: .poster), ArtKey(id: current, kind: .backdrop)]
                next = row["parent_id"]
            }
            return art
        case .song:
            guard let song = try PlaylistRows.songs(db, [id])[id] else { return [] }
            return [song.albumId, song.artistId, song.albumArtistId].map { ArtKey(id: $0, kind: .poster) }
        case .video:
            guard
                let channel = try Int64.fetchOne(
                    db, sql: "SELECT parent_id FROM item WHERE id = ? AND kind = 'video'", arguments: [id])
            else { return [] }
            return [ArtKey(id: id, kind: .poster), ArtKey(id: channel, kind: .poster)]
        }
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
