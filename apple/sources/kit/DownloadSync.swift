import Foundation
import GRDB
import OpenAPIRuntime
import RabbitEarsAPI

extension DownloadStore {
    /// What downloading the target at a quality would keep, as the server
    /// resolves it now for this device and profile.
    public func plan(_ target: DownloadTarget, quality: DownloadQuality, profile: UID) async throws -> DownloadPlan {
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
        _ target: DownloadTarget, quality: DownloadQuality, profile: UID
    ) async throws -> DownloadPlan? {
        let plan = try await plan(target, quality: quality, profile: profile)
        if needsConfirmation(plan) { return plan }
        keep(plan)
        return nil
    }

    private func resolve(
        _ target: DownloadTarget, quality: DownloadQuality, profile: UID, _ link: Link
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
    public func sync(profile: UID) async {
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

    private func refresh(profile: UID, _ link: Link) async {
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
        // Art moves to a new address, so what is on the device is kept at the one named now.
        for id in held {
            if let title = ledger.titles[id], case .onDevice = title.state {
                await describe(title, profile: profile, link)
            }
        }
        for (id, title) in ledger.titles {
            if case .failed = title.state { ledger.titles[id]?.state = .pending }
        }
        collect()
    }

    /// The server's unauthorized is a device it no longer knows, its not_found such a profile.
    private func lost(_ error: any Error, profile: UID) {
        guard let api = APIError.from(error) else { return }
        if api.code == .unauthorized {
            wipe()
        } else if api.code == .notFound {
            wipe(profile: profile)
        }
    }

    /// Keeps the artwork a collection or playlist shows with; a playlist's
    /// is its art title's, as the replica reads it to the profile.
    func describe(_ target: DownloadTarget, profile: UID, _ link: Link) async {
        guard target.scope != .item else { return }
        let art =
            (try? await replica?.read { db -> [String] in
                let keys: [ArtKey]
                switch target.scope {
                case .item: return []
                case .collection: keys = [.poster, .backdrop].map { ArtKey(id: target.id, kind: $0, collection: true) }
                case .playlist:
                    guard let art = try PlaylistRows.playlist(db, profile: profile, id: target.id)?.artItemId
                    else { return [] }
                    keys = [ArtKey(id: art, kind: .poster)]
                }
                return try Self.addresses(keys, profile, db)
            }) ?? []
        let files = await keepArt(art, link.client)
        if let index = ledger.requests.firstIndex(where: { $0.profileId == profile && $0.target == target }) {
            ledger.requests[index].art = files
        }
        save()
    }

    // MARK: Artwork

    /// Keeps the artwork a title shows with, its parents' included, at the
    /// addresses the replica names for `profile`; whatever the server does
    /// not answer is left out.
    func describe(_ title: StoredTitle, profile: UID, _ link: Link) async {
        let (id, kind) = (title.itemId, title.kind)
        let art =
            (try? await replica?.read { db in try Self.addresses(Self.art(of: id, kind, profile, db), profile, db) })
            ?? []
        let files = await keepArt(art, link.client)
        ledger.titles[title.itemId]?.art = files
    }

    /// Each key's address for the profile once, in the keys' order; art with none is left out.
    private nonisolated static func addresses(_ keys: [ArtKey], _ profile: UID, _ db: Database) throws -> [String] {
        var seen = Set<String>()
        return try keys.compactMap { try $0.address(for: profile, db) }.filter { seen.insert($0).inserted }
    }

    /// A movie or episode and each item above it, both images; a song's
    /// album, performer and album artist; a video and its channel.
    private nonisolated static func art(
        of id: UID, _ kind: DownloadTitle.KindPayload, _ profile: UID, _ db: Database
    ) throws -> [ArtKey] {
        switch kind {
        case .movie, .episode:
            var art: [ArtKey] = []
            var next: UID? = id
            while let current = next,
                let row = try Row.fetchOne(db, sql: "SELECT parent_id FROM item WHERE id = ?", arguments: [current])
            {
                art += [ArtKey(id: current, kind: .poster), ArtKey(id: current, kind: .backdrop)]
                next = row["parent_id"]
            }
            return art
        case .song:
            guard let song = try PlaylistRows.songs(db, profile, [id])[id] else { return [] }
            return [song.albumId, song.artistId, song.albumArtistId].map { ArtKey(id: $0, kind: .poster) }
        case .video:
            guard
                let channel = try UID.fetchOne(
                    db, sql: "SELECT parent_id FROM item WHERE id = ? AND kind = 'video'", arguments: [id])
            else { return [] }
            return [ArtKey(id: id, kind: .poster), ArtKey(id: channel, kind: .poster)]
        }
    }

    /// The shelf's files of the images at `addresses`, each fetched once; one
    /// the server does not answer is left out.
    func keepArt(_ addresses: [String], _ client: Client) async -> [String] {
        var files: [String] = []
        for address in addresses {
            guard let path = ArtworkStore.artworkPath(address) else { continue }
            let file = OfflineShelf.file(path)
            if !ledger.shelf.art.contains(file) {
                guard let body = try? await client.getArtwork(path: path).ok.body.image_Ast_,
                    let data = try? await Data(collecting: body, upTo: 16 << 20)
                else { continue }
                try? FileManager.default.createDirectory(at: art, withIntermediateDirectories: true)
                guard (try? data.write(to: art.appending(path: file), options: .atomic)) != nil else { continue }
                ledger.shelf.art.insert(file)
            }
            files.append(file)
        }
        return files
    }
}
