import Foundation
import RabbitEarsAPI

/// A title playing from its file on the device, which the server never hears of.
struct LocalSession: Sendable {
    let itemId: Int64
    let profileId: Int64
    let editionId: Int64?
    let stream: PlaybackStream
}

extension DownloadStore {
    /// A session for a title on the device for the profile, playing its
    /// file from the start asked for, else from the profile's resume
    /// position; nil when it is not on the device, or is another edition
    /// than the request names and `anyEdition` is off.
    func startLocal(_ request: Components.Schemas.PlaybackRequest, anyEdition: Bool) -> LocalAnswer? {
        guard let title = onDevice(request.itemId, profile: request.profileId), let file = file(of: title),
            anyEdition || request.editionId == nil || request.editionId == title.editionId
        else { return nil }
        let watch = ledger.shelf.watch[request.profileId]?[request.itemId]
        let resume = watch.flatMap { $0.editionId == nil || $0.editionId == title.editionId ? $0.positionMs : nil }
        nextSession -= 1
        let sidecars = title.subtitles.map { subtitle in
            Components.Schemas.Sidecar(
                trackId: subtitle.trackId, language: subtitle.language, title: subtitle.title, format: .webvtt,
                forced: subtitle.isForced, url: media.appending(path: subtitle.file).absoluteString)
        }
        let stream = PlaybackStream(
            sessionId: nextSession, mediaFileId: 0,
            entry: .init(
                position: 0, verdict: .directPlay, videoAction: .copy, audioAction: .copy,
                subtitleAction: sidecars.isEmpty ? .none : .sidecar, bad: false),
            streamUrl: file.absoluteString, streamKind: .file, positionMs: request.positionMs ?? resume ?? 0,
            negotiated: .init(verdict: .directPlay, width: 0, height: 0, bitrate: 0), rungs: [], sidecars: sidecars)
        sessions[nextSession] = LocalSession(
            itemId: title.itemId, profileId: request.profileId, editionId: title.editionId, stream: stream)
        return .json(stream, status: 201)
    }

    /// What a local session's calls answer: its position is kept as watch
    /// state, and everything else carries on with the same file.
    func session(_ id: Int64, _ call: LocalCall) async -> LocalAnswer {
        guard let session = sessions[id] else { return .notFound }
        switch call.operation {
        case "reportPlaybackPosition":
            if let report = call.decode(Components.Schemas.PositionReport.self) {
                played(session, to: report.positionMs)
            }
            return .noContent
        case "reportPlaybackThroughput":
            if let position = call.decode(Components.Schemas.ThroughputTelemetry.self)?.positionMs {
                played(session, to: position)
            }
        case "endPlayback":
            if let position = call.number("positionMs") { played(session, to: position) }
            sessions[id] = nil
            if !isOffline, let link { _ = await flushWatch(profile: session.profileId, link) }
            return .noContent
        case "getPlaybackSession", "movePlaybackSession": return .notFound
        default: break
        }
        return .json(Components.Schemas.PlaybackUpdate(action: ._continue, stream: session.stream))
    }

    /// 90% played is watched, which clears the resume position, as the
    /// server counts it. Songs keep no watch state.
    private func played(_ session: LocalSession, to positionMs: Int64) {
        guard let title = ledger.titles[session.itemId], title.kind != .song else { return }
        let runtime =
            title.runtimeMs ?? ledger.shelf.items[title.itemId]?.metadata?.runtimeMinutes.map { Int64($0) * 60_000 }
            ?? ledger.shelf.videos[title.itemId]?.durationMs
        let finished = runtime.map { $0 > 0 && positionMs * 10 >= $0 * 9 } ?? false
        let before =
            unsynced(session.profileId)[session.itemId]?.watched
            ?? ledger.shelf.watch[session.profileId]?[session.itemId]?.watched ?? false
        record(
            watched: before || finished, positionMs: finished ? 0 : positionMs, editionId: session.editionId,
            itemId: session.itemId, profile: session.profileId)
    }

    // MARK: Up next

    /// The next downloaded title the profile may play: a playlist's next
    /// row, the show's next episode, the collection's next movie, the
    /// channel's next video.
    func upNext(_ call: LocalCall) -> LocalAnswer {
        guard let profile = call.id(after: "profiles"), let itemId = call.id(after: "up-next") else {
            return .notFound
        }
        let here = { (id: Int64) in self.onDevice(id, profile: profile) != nil }
        let shelf = ledger.shelf
        if let playlist = call.number("playlistId"), let index = call.number("index"),
            let rows = shelf.playlists[playlist]?.rows
        {
            let start = Int(index) + 1
            guard start < rows.count,
                let next = rows[start...].firstIndex(where: { here($0.itemId) && $0.item != nil }),
                let item = rows[next].item
            else { return .notFound }
            return .json(
                Components.Schemas.UpNext(
                    itemId: item.id, kind: item.kind == .episode ? .episode : .movie, title: upNextTitle(item),
                    editionId: rows[next].editionId, index: next, item: item))
        }
        if let video = shelf.videos[itemId] {
            let videos = shelf.videos.values.filter { $0.channelId == video.channelId && here($0.id) }
                .sorted { ($0.publishedOn ?? "", $0.id) < ($1.publishedOn ?? "", $1.id) }
            guard let index = videos.firstIndex(where: { $0.id == itemId }), index + 1 < videos.count else {
                return .notFound
            }
            let next = videos[index + 1]
            return .json(Components.Schemas.UpNext(itemId: next.id, kind: .video, title: next.title, video: next))
        }
        guard let item = shelf.items[itemId] else { return .notFound }
        let catalog = Catalog(
            items: Array(shelf.items.values.filter { here($0.id) || $0.kind == .show || $0.kind == .season }))
        var next: Item?
        if item.kind == .episode {
            next = catalog.nextEpisode(after: item)
        } else if let movies = shelf.collections.values.first(where: { $0.movieIds.contains(itemId) })?.movieIds,
            let index = movies.firstIndex(of: itemId)
        {
            next = movies.dropFirst(index + 1).first(where: here).flatMap { shelf.items[$0] }
        }
        guard let next else { return .notFound }
        return .json(
            Components.Schemas.UpNext(
                itemId: next.id, kind: next.kind == .episode ? .episode : .movie, title: upNextTitle(next),
                item: next))
    }

    private func upNextTitle(_ item: Item) -> String {
        guard item.kind == .episode else { return Catalog.title(item) }
        let show = ledger.shelf.lineage(item.id).first { $0.kind == .show }.map(Catalog.title)
        return [show, Format.episodeCode(item), Catalog.title(item)].compactMap { $0 }.joined(separator: " · ")
    }
}
