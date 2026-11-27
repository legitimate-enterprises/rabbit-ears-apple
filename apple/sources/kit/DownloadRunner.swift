import Foundation
import Observation
import OpenAPIRuntime
import RabbitEarsAPI

extension DownloadStore {
    /// While signed in: claims every waiting title that fits the
    /// allowance, oldest request first, in one batch, so the server
    /// prepares them back to back; then starts a transfer for each claimed
    /// title the network lets go, all at once, and returns once every
    /// transfer in flight ends. Claims are made whatever the network. One
    /// that would pass the allowance waits for space, and a smaller one
    /// behind it may go first. One the server stops goes again by itself.
    public func pump() async {
        guard let link else { return }
        guard !pumping else {
            pumpAgain = true
            return
        }
        pumping = true
        let next = nextTitles()
        var stopped = !(await claim(next, link))
        let path = facts().path
        let wait = DownloadState.waiting(
            wifiOnly: ledger.wifiOnly, expensive: path.expensive, constrained: path.constrained)
        for id in next where ledger.titles[id]?.claim != nil && transfers[id] == nil {
            if let wait {
                ledger.titles[id]?.state = wait
                continue
            }
            transfers[id] = Task { [weak self] in
                let going = await self?.download(id, link) ?? true
                self?.transfers[id] = nil
                return going
            }
        }
        await releaseFetched(link)
        save()
        // Later pumps claim and start what arrives meanwhile.
        pumping = false
        if pumpAgain {
            pumpAgain = false
            Task { await pump() }
        }
        if ledger.titles.values.contains(where: { $0.state == .waitingForWiFi || $0.state == .waitingForLowData }) {
            pumpOnPathChange()
        }
        while let transfer = transfers.values.first {
            if !(await transfer.value) { stopped = true }
        }
        if stopped, self.link != nil, ledger.titles.values.contains(where: { $0.state == .pending }) {
            pumpLater()
        } else {
            stops = 0
        }
        save()
    }

    /// Pumps again after a wait that starts at the poll interval and doubles
    /// with each pump stopped in a row, up to five minutes; at most one such
    /// wait is armed at a time.
    private func pumpLater() {
        guard !waitingToPump else { return }
        waitingToPump = true
        let wait = min(pollInterval * (1 << min(stops, 10)), .seconds(300))
        stops += 1
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: wait)
            self?.waitingToPump = false
            await self?.pump()
        }
    }

    /// Pumps once the network path the facts read changes, as when the
    /// device joins Wi-Fi; at most one such wait is armed at a time.
    private func pumpOnPathChange() {
        guard !watchingPath else { return }
        watchingPath = true
        withObservationTracking {
            _ = facts().path
        } onChange: {
            Task { @MainActor [weak self] in
                self?.watchingPath = false
                await self?.pump()
            }
        }
    }

    /// The titles to claim and fetch now, in download order: each one
    /// waiting and not in flight that fits the allowance.
    func nextTitles() -> [UID] {
        let order = ledger.requests.sorted { $0.createdAt < $1.createdAt }.flatMap(\.titles)
        var used = usedBytes
        var seen = Set<UID>()
        var next: [UID] = []
        for id in order where seen.insert(id).inserted && transfers[id] == nil {
            guard let title = ledger.titles[id] else { continue }
            switch title.state {
            case .pending, .waitingForWiFi, .waitingForLowData, .waitingForSpace: break
            default: continue
            }
            if used + title.sizeBytes > ledger.allowanceBytes {
                ledger.titles[id]?.state = .waitingForSpace
                continue
            }
            used += title.sizeBytes
            next.append(id)
        }
        return next
    }

    /// Claims those of the titles not yet claimed, in one batch per profile
    /// and quality of at most 5000, in order; the server converts them back
    /// to back from then on. A title the server refuses fails alone. False
    /// when the server is gone or refuses the device for now.
    func claim(_ ids: [UID], _ link: Link) async -> Bool {
        struct Batch {
            let profile: UID
            let quality: DownloadQuality
            var ids: [UID]
        }
        var batches: [Batch] = []
        let me = me
        for id in ids {
            guard let title = ledger.titles[id], title.claim == nil, let profile = claimant(id, me) else { continue }
            if let index = batches.firstIndex(where: {
                $0.profile == profile && $0.quality == title.quality && $0.ids.count < 5000
            }) {
                batches[index].ids.append(id)
            } else {
                batches.append(Batch(profile: profile, quality: title.quality, ids: [id]))
            }
        }
        for batch in batches {
            let titles = batch.ids.compactMap { ledger.titles[$0] }.map {
                Components.Schemas.DownloadBatchTitle(itemId: $0.itemId, editionId: $0.editionId)
            }
            do {
                let snapshot = await link.endpoint.snapshot(facts(), checkedWith: link.client, maxBitrate: nil)
                let results = try await link.client.createDownloads(
                    path: .init(profileId: batch.profile),
                    body: .json(.init(titles: titles, quality: batch.quality, snapshot: snapshot))
                ).ok.body.json.results
                for result in results where ledger.titles[result.itemId] != nil {
                    if let download = result.download {
                        claimed(download, profile: batch.profile)
                    } else {
                        let error = result.error
                        ledger.titles[result.itemId]?.state = .failed(
                            error?.code == .conflict
                                ? "Nothing this device can keep" : error?.message ?? "The server answered nothing")
                    }
                }
                save()
            } catch {
                guard let api = APIError.from(error) else { return false }
                for id in batch.ids where !refused(id, status: api.status, code: api.code, message: api.message) {
                    return false
                }
            }
        }
        return true
    }

    /// Who claims the title now: the active profile when it asked for it,
    /// else a profile the server answers for that did. Another adult's title
    /// waits for them.
    private func claimant(_ id: UID, _ me: Components.Schemas.Me?) -> UID? {
        let asking = ledger.requests.filter { $0.titles.contains(id) }.map(\.profileId)
        if let active = me?.activeProfileId, asking.contains(active) { return active }
        return asking.first { answers(for: $0, me) }
    }

    /// Whether the server answers for the profile now: the active one, or a
    /// kid while an adult is. Not knowing who is active, it may.
    private func answers(for profile: UID, _ me: Components.Schemas.Me?) -> Bool {
        guard let me else { return true }
        let kids = Set(me.profiles.filter { $0.kind == .kid }.map(\.id))
        return profile == me.activeProfileId || !kids.contains(me.activeProfileId) && kids.contains(profile)
    }

    private func claimed(_ download: ServerDownload, profile: UID) {
        let id = download.itemId
        ledger.titles[id]?.claim = DownloadClaim(id: download.id, profileId: profile, container: download.container)
        ledger.titles[id]?.sizeBytes = download.sizeBytes
    }

    /// Fetches a claimed title once the server has it ready, with its
    /// subtitles and artwork, then releases the claim. A claim
    /// the server lost is made again once. False stops the pump: the server
    /// is gone or refuses the device for now.
    func download(_ id: UID, _ link: Link, again: Bool = false) async -> Bool {
        guard let title = ledger.titles[id], let claim = title.claim else { return true }
        let name = "\(id).\(claim.container)"
        let destination = media.appending(path: name)
        let request = fileRequest(claim.file, link)
        let fetch: (Data?) async throws -> Void = { [downloader] resume in
            try await downloader.fetch(request, to: destination, resumeData: resume) { share in
                Task { @MainActor [weak self] in self?.progressed(id, share) }
            }
        }
        do {
            // Preparing until the first bytes arrive, when the transfer's own progress shows.
            ledger.titles[id]?.state = .preparing(0)
            // A background transfer may have landed the file after the process that started it ended.
            let landed = FileManager.default.fileExists(atPath: destination.path(percentEncoded: false))
            if !landed { try await fetch(title.resumeData) }
            let ready = try await link.client.getDownload(
                path: .init(profileId: claim.profileId, downloadId: claim.id)
            ).ok.body.json
            let size = (try? destination.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
            if landed, size.map(Int64.init) != ready.sizeBytes { try await fetch(nil) }
            ledger.titles[id]?.sizeBytes = ready.sizeBytes
            let subtitles = await keepSubtitles(of: ready, link)
            await describe(title, link)
            guard ledger.titles[id] != nil else {
                try? FileManager.default.removeItem(at: destination)
                return true
            }
            ledger.titles[id]?.file = name
            ledger.titles[id]?.mediaFileId = ready.mediaFileId
            ledger.titles[id]?.subtitles = subtitles
            ledger.titles[id]?.resumeData = nil
            ledger.titles[id]?.state = .onDevice
            save()
            if await release(claim, link) {
                ledger.titles[id]?.claim = nil
                save()
            }
            return true
        } catch {
            return await stopped(id, by: error, link, again: again)
        }
    }

    /// The text subtitles of a ready download that reached the device.
    private func keepSubtitles(of ready: ServerDownload, _ link: Link) async -> [StoredSubtitle] {
        var subtitles: [StoredSubtitle] = []
        for subtitle in ready.subtitles {
            let file = "\(ready.itemId)-\(subtitle.trackId).vtt"
            guard
                (try? await downloader.fetch(
                    fileRequest(subtitle.url, link), to: media.appending(path: file), resumeData: nil,
                    progress: { _ in })) != nil
            else { continue }
            subtitles.append(
                StoredSubtitle(
                    trackId: subtitle.trackId, language: subtitle.language, title: subtitle.title,
                    isForced: subtitle.isForced, file: file))
        }
        return subtitles
    }

    /// Where a title stands after its fetch threw; false stops the pump.
    private func stopped(_ id: UID, by error: any Error, _ link: Link, again: Bool) async -> Bool {
        switch error {
        case DownloadFailure.interrupted(let resumeData):
            guard ledger.titles[id] != nil else { return true }
            ledger.titles[id]?.resumeData = resumeData
            ledger.titles[id]?.state = .pending
            return false
        case DownloadFailure.status(404, _):
            return await reclaim(id, link, again: again)
        case DownloadFailure.status(let status, let message):
            return refused(id, status: status, message: message)
        default:
            guard let api = APIError.from(error) else {
                ledger.titles[id]?.state = .pending
                return false
            }
            if api.status == 404 { return await reclaim(id, link, again: again) }
            return refused(id, status: api.status, code: api.code, message: api.message)
        }
    }

    /// The claim expired or went: claimed again once, then the title fails.
    private func reclaim(_ id: UID, _ link: Link, again: Bool) async -> Bool {
        // Another profile's 404 is the server not answering for it now; its claim waits for it.
        if let profile = ledger.titles[id]?.claim?.profileId, !answers(for: profile, me) {
            ledger.titles[id]?.state = .pending
            return true
        }
        ledger.titles[id]?.claim = nil
        ledger.titles[id]?.resumeData = nil
        guard !again else {
            ledger.titles[id]?.state = .failed("The server answered 404")
            return true
        }
        ledger.titles[id]?.state = .pending
        guard await claim([id], link) else { return false }
        return await download(id, link, again: true)
    }

    /// Lets the server forget the claims of titles already on the device.
    private func releaseFetched(_ link: Link) async {
        for (id, title) in ledger.titles where title.state == .onDevice {
            guard let claim = title.claim, await release(claim, link) else { continue }
            ledger.titles[id]?.claim = nil
        }
    }

    /// Whether the server no longer holds the claim, released now or gone before.
    func release(_ claim: DownloadClaim, _ link: Link) async -> Bool {
        guard answers(for: claim.profileId, me) else { return false }
        do {
            _ = try await link.client.deleteDownload(path: .init(profileId: claim.profileId, downloadId: claim.id))
                .noContent
            return true
        } catch {
            return APIError.from(error)?.code == .notFound
        }
    }

    /// The server's unauthorized is a device signed out. Another 401, as a
    /// proxy's or a file fetch's, and a 403, a device at Who's watching,
    /// wait; 404 is a download gone, which the next pump claims again.
    private func refused(_ id: UID, status: Int, code: APIError.Code? = nil, message: String? = nil) -> Bool {
        ledger.titles[id]?.resumeData = nil
        switch status {
        case 401 where code == .unauthorized:
            wipe()
            return false
        case 401, 403:
            ledger.titles[id]?.state = .pending
            return false
        case 404:
            ledger.titles[id]?.state = .pending
            return true
        case 409 where message != nil:
            ledger.titles[id]?.state = .failed("Nothing this device can keep")
            return true
        default:
            ledger.titles[id]?.state = .failed(message ?? "The server answered \(status)")
            return true
        }
    }

    private func progressed(_ id: UID, _ share: Double) {
        switch ledger.titles[id]?.state {
        case .preparing, .downloading: ledger.titles[id]?.state = .downloading(share)
        default: return
        }
    }

    /// Low Data Mode never carries a transfer, and a metered path only
    /// with Wi-Fi only off; a transfer keeps the setting it started with.
    private func fileRequest(_ path: String, _ link: Link) -> URLRequest {
        var request = URLRequest(url: link.endpoint.resolve(path))
        request.setValue("Bearer \(link.token)", forHTTPHeaderField: "Authorization")
        request.allowsExpensiveNetworkAccess = !ledger.wifiOnly
        request.allowsConstrainedNetworkAccess = false
        return request
    }
}
