import Foundation
import RabbitEarsAPI

/// Where a local play's watch state goes, as queued actions. Each returns
/// once the replica holds the change; the queue sends it on to the server.
struct LocalPlays {
    /// putWatchState: where the profile left the item, watched as it was.
    let progress:
        @MainActor (
            _ profile: UID, _ item: UID, _ edition: UID?, _ positionMs: Int64, _ watched: Bool, _ at: Date
        ) async -> Void
    /// recordPlay: one finished play, which the server counts and marks watched from the start.
    let finished: @MainActor (_ profile: UID, _ item: UID, _ edition: UID?, _ at: Date) async -> Void
}

/// A title playing from its file on the device, which the server never hears of.
struct LocalSession: Sendable {
    let itemId: UID
    let profileId: UID
    let editionId: UID?
    let stream: PlaybackStream
    var savedMs: Int64?
    var finished = false
}

extension DownloadStore {
    /// A session for a title on the device for the profile, playing its
    /// file from the start asked for, else from the profile's resume
    /// position; nil when it is not on the device, or is another edition
    /// than the request names and `anyEdition` is off.
    func startLocal(_ request: Components.Schemas.PlaybackRequest, anyEdition: Bool) async -> LocalAnswer? {
        guard let title = onDevice(request.itemId, profile: request.profileId), let file = file(of: title),
            let mediaFileId = title.mediaFileId,
            anyEdition || request.editionId == nil || request.editionId == title.editionId
        else { return nil }
        let watch = await watchState(request.itemId, profile: request.profileId)
        let resume = watch.flatMap { $0.editionId == nil || $0.editionId == title.editionId ? $0.positionMs : nil }
        let id = UID.new()
        let sidecars = title.subtitles.map { subtitle in
            Components.Schemas.Sidecar(
                trackId: subtitle.trackId, language: subtitle.language, title: subtitle.title, format: .webvtt,
                forced: subtitle.isForced, url: media.appending(path: subtitle.file).absoluteString)
        }
        let stream = PlaybackStream(
            sessionId: id, mediaFileId: mediaFileId,
            entry: .init(
                position: 0, verdict: .directPlay, videoAction: .copy, audioAction: .copy,
                subtitleAction: sidecars.isEmpty ? .none : .sidecar, bad: false),
            streamUrl: file.absoluteString, streamKind: .file, positionMs: request.positionMs ?? resume ?? 0,
            negotiated: .init(verdict: .directPlay, width: 0, height: 0, bitrate: 0), rungs: [], sidecars: sidecars)
        sessions[id] = LocalSession(
            itemId: title.itemId, profileId: request.profileId, editionId: title.editionId, stream: stream)
        return .json(stream, status: 201)
    }

    /// What a local session's calls answer: its position is kept as watch
    /// state, and everything else carries on with the same file.
    func session(_ id: UID, _ call: LocalCall) async -> LocalAnswer {
        guard let session = sessions[id] else { return .notFound }
        switch call.operation {
        case "reportPlaybackPosition":
            if let report = call.decode(Components.Schemas.PositionReport.self) {
                await played(id, to: report.positionMs)
            }
            return .noContent
        case "reportPlaybackThroughput":
            if let position = call.decode(Components.Schemas.ThroughputTelemetry.self)?.positionMs {
                await played(id, to: position)
            }
        case "endPlayback":
            if let position = call.number("positionMs") { await played(id, to: position) }
            sessions[id] = nil
            return .noContent
        case "getPlaybackSession", "movePlaybackSession": return .notFound
        default: break
        }
        return .json(Components.Schemas.PlaybackUpdate(action: ._continue, stream: session.stream))
    }

    /// 90% played is one finished play, counted once, after which the
    /// session saves nothing more: the play marks it watched. Until then
    /// each new position is saved, watched as it was. Songs keep no watch
    /// state.
    private func played(_ id: UID, to positionMs: Int64) async {
        guard var session = sessions[id], !session.finished, session.savedMs != positionMs, let plays,
            let title = ledger.titles[session.itemId], title.kind != .song
        else { return }
        session.finished = title.runtimeMs.map { $0 > 0 && positionMs * 10 >= $0 * 9 } ?? false
        session.savedMs = positionMs
        // Kept before waiting, so a report arriving meanwhile is judged against this one.
        sessions[id] = session
        if session.finished {
            await plays.finished(session.profileId, session.itemId, session.editionId, now())
            await applyKeepPolicy(session.profileId)
        } else {
            let watched = await watchState(session.itemId, profile: session.profileId)?.watched ?? false
            await plays.progress(session.profileId, session.itemId, session.editionId, positionMs, watched, now())
        }
    }
}

extension PlaybackStream {
    /// A local session's, whose file and sidecars are on the device.
    var isOnDevice: Bool { URL(string: streamUrl)?.isFileURL == true }

    /// The sidecars as the subtitle menu's tracks, all text.
    var sidecarTracks: [Track] {
        sidecars.map { sidecar in
            Track(
                id: sidecar.trackId, streamIndex: 0, kind: .subtitle, codec: sidecar.format.rawValue,
                language: sidecar.language, title: sidecar.title, isDefault: false, isForced: sidecar.forced,
                subtitleIsText: true)
        }
    }
}
