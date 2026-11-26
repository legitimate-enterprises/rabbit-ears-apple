import Foundation
import Observation
import RabbitEarsAPI

public typealias PlaybackStream = Components.Schemas.PlaybackStream

/// What plays the stream; AVPlayer in the app, a recorder in tests.
@MainActor
public protocol VideoOutput: AnyObject {
    /// bufferGoal is the seconds past the playhead to hold; zero leaves the output its own buffer.
    func load(_ url: URL, startingAt seconds: Double, bufferGoal: TimeInterval)
    func play()
    func pause()
    func stop()
    func seek(toMs ms: Int64)
    /// Plays from ms once delay seconds have passed, as precisely as the output can.
    func play(atMs ms: Int64, after delay: TimeInterval)
    var positionMs: Int64 { get }
    var isPaused: Bool { get }
    /// Waiting for media to play, as while a seek fills the buffer.
    var isBuffering: Bool { get }
    func telemetry() async -> Components.Schemas.ThroughputTelemetry
    var onFailure: ((String) -> Void)? { get set }
    var onStall: (() -> Void)? { get set }
}

/// One playback session: starts it with the full snapshot, sends a single
/// group when the device changes, walks the plan on failure, and reports
/// position and throughput. The server decides everything else.
@MainActor
@Observable
public final class PlayerModel {
    public enum SubtitleChoice: Hashable, Sendable {
        case off, forcedOnly
        case track(Int64)
    }

    /// The movie, episode or video started; nil for a station, whose program the server picks.
    private let item: Item?
    public let output: any VideoOutput
    public private(set) var stream: PlaybackStream?
    public private(set) var adjusting = false
    public private(set) var error: String?
    public private(set) var subtitleChoice = SubtitleChoice.forcedOnly
    public private(set) var quality = QualityChoice.auto
    public private(set) var rungInUse: RungInUse?
    private var cues: [SubtitleCue] = []
    /// Rises with every cue load, so text arriving for an older one is dropped.
    private var cueLoads = 0
    /// The file in play, read once for the tracks its menu lists.
    private var file: Components.Schemas.MediaFile?
    var audioTrackId: Int64?
    private var reporter: Task<Void, Never>?
    /// Capability groups whose last send failed, which the next tick sends again.
    private var unsent: Set<CapabilityGroup> = []
    var stopped = false
    /// The station tuned in to, which picks every program.
    var station: StationTuner?
    /// A tune-in is in flight; another ask while it runs is dropped, so one tune-in makes one session.
    var tuning = false
    /// A change was heard during the tune-in in flight, which asks once more when it is done.
    var tuneAgain = false
    /// The facts and quality the session in play was asked with.
    private var askedWith: (facts: DeviceFacts, quality: QualityChoice)?

    private let client: Client
    private let endpoint: ServerEndpoint
    private let profileId: Int64
    /// The playlist whose play order this item is a row of.
    private let playlistId: Int64?
    private let capabilities: any CapabilitySource
    private let fetchText: @Sendable (URL) async throws -> String
    /// What this device is called in copy, as in "on this Mac".
    private let device: String

    public init(
        client: Client, endpoint: ServerEndpoint, profileId: Int64, item: Item?, output: any VideoOutput,
        capabilities: any CapabilitySource, device: String = "Mac", playlistId: Int64? = nil,
        fetchText: @escaping @Sendable (URL) async throws -> String = { url in
            String(bytes: try await URLSession.shared.data(from: url).0, encoding: .utf8) ?? ""
        }
    ) {
        self.client = client
        self.endpoint = endpoint
        self.profileId = profileId
        self.item = item
        self.output = output
        self.capabilities = capabilities
        self.fetchText = fetchText
        self.device = device
        self.playlistId = playlistId
        output.onFailure = { [weak self] reason in Task { await self?.playerFailed(reason) } }
        output.onStall = { [weak self] in Task { await self?.stalled() } }
        capabilities.onChange = { [weak self] group in Task { await self?.capabilitiesChanged(group) } }
    }

    public var pill: String {
        stream.map { Format.pill($0.negotiated, auto: $0.auto == true ? currentRung(in: $0) : nil) } ?? ""
    }

    /// Away from home Auto comes first; Original and the rungs follow. At
    /// home there is no Auto, so an unpicked quality shows as Original.
    public var qualityOptions: [QualityOption] {
        guard let stream else { return [] }
        let away = stream.away == true
        let chosen = effectiveQuality(in: stream)
        var options: [QualityOption] = []
        if away {
            options.append(
                QualityOption(
                    choice: .auto, name: "Auto",
                    detail:
                        "Now \(Format.resolution(height: currentRung(in: stream).height)) · adjusts to your connection",
                    verdict: .videoTranscode, selected: chosen == .auto, blocked: false))
        }
        for (index, rung) in stream.rungs.enumerated() {
            var label = Format.resolution(width: rung.width, height: rung.height)
            if index == 0, stream.negotiated.hdrFormat != nil { label += " HDR" }
            let choice: QualityChoice = index == 0 ? .original : .rung(rung.bitrate)
            options.append(
                QualityOption(
                    choice: choice, name: index == 0 ? "Original" : label,
                    detail: "\(label) · \(Format.bitrate(rung.bitrate))", verdict: rung.verdict,
                    selected: chosen == choice, blocked: rung.blocked == true))
        }
        return options
    }

    /// Where the pointer is on the scrub bar, as a frame URL; nil when the file has no previews.
    public func previewURL(at seconds: Double) -> URL? {
        stream?.previews?.url(at: seconds, endpoint: endpoint)
    }

    /// Every subtitle track of the file in play, text or bitmap; the
    /// stream's sidecars hold only the one being drawn.
    public var subtitleTracks: [Track] { file.map { MediaSummary($0).subtitles } ?? [] }

    public func cue(at seconds: Double) -> String? {
        subtitleChoice == .off ? nil : cues.text(at: seconds)
    }

    /// A nil edition plays the default; a nil position resumes from the
    /// profile's watch state when it belongs to the edition played.
    public func start(audioTrackId: Int64? = nil, editionId: Int64? = nil, positionMs: Int64? = nil) async {
        self.audioTrackId = audioTrackId
        await begin { [client, profileId, item, playlistId] snapshot in
            let request = Components.Schemas.PlaybackRequest(
                profileId: profileId, itemId: item?.id ?? 0, editionId: editionId, audioTrackId: audioTrackId,
                positionMs: positionMs, playlistId: playlistId, snapshot: snapshot)
            return try await client.startPlayback(body: .json(request)).created.body.json
        }
    }

    /// Starts a session from what `ask` answers for this device's snapshot;
    /// an answer of nil starts nothing. It runs in a task of its own, since
    /// a closing view cancels the caller's: a start cancelled in flight
    /// would leave the session the server made with nothing to end it.
    func begin(_ ask: @escaping (Components.Schemas.CapabilitySnapshot) async throws -> PlaybackStream?) async {
        await Task { [self] in
            error = nil
            let facts = capabilities.facts()
            askedWith = (facts, quality)
            let snapshot = await endpoint.snapshot(
                facts, checkedWith: client, maxBitrate: quality.maxBitrate, auto: quality == .auto)
            let answer: PlaybackStream?
            do {
                answer = try await ask(snapshot)
            } catch {
                if !stopped { fail(error) }
                return
            }
            guard let started = answer else { return }
            // Closed while the server was starting it: end the session, never play it.
            if stopped {
                _ = try? await client.endPlayback(path: .init(sessionId: started.sessionId)).noContent
                return
            }
            await load(started)
            await catchUp(since: facts)
            guard !stopped else { return }
            reporter?.cancel()
            reporter = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(10))
                    guard let self, !Task.isCancelled else { return }
                    await self.tick()
                }
            }
        }.value
    }

    /// A station asks for playback again; anything else sends the group that
    /// changed. A failed send never stops playback; the next tick retries it.
    public func capabilitiesChanged(_ group: CapabilityGroup) async {
        guard let session = stream?.sessionId else { return }
        if let station {
            // Starting a stream raises screen and route notifications that change nothing it was asked with.
            if let askedWith, askedWith.facts == capabilities.facts(), askedWith.quality == quality { return }
            return await retune(station)
        }
        let facts = capabilities.facts()
        if group == .network { await endpoint.confirmHome(using: client, on: facts.path) }
        let sent = await update(surfacing: false) { client in
            switch group {
            case .display:
                try await client.updatePlaybackDisplay(
                    path: .init(sessionId: session), body: .json(CapabilitySnapshotBuilder.display(facts.screen))
                ).ok.body.json
            case .audioRoute:
                try await client.updatePlaybackAudioRoute(
                    path: .init(sessionId: session), body: .json(CapabilitySnapshotBuilder.audioRoute(facts.route))
                ).ok.body.json
            case .network:
                try await client.updatePlaybackNetwork(
                    path: .init(sessionId: session),
                    body: .json(
                        CapabilitySnapshotBuilder.network(
                            facts.path, server: endpoint, maxBitrate: quality.maxBitrate, auto: quality == .auto))
                ).ok.body.json
            }
        }
        if sent { unsent.remove(group) } else { unsent.insert(group) }
    }

    public func selectQuality(_ option: QualityOption) async {
        guard !option.blocked, let stream, option.choice != effectiveQuality(in: stream) else { return }
        quality = option.choice
        await capabilitiesChanged(.network)
    }

    public func selectSubtitles(_ choice: SubtitleChoice) async {
        subtitleChoice = choice
        guard let session = stream?.sessionId else { return }
        var selection = Components.Schemas.TrackSelection(audioTrackId: audioTrackId)
        if case .track(let id) = choice { selection.subtitleTrackId = id }
        await update { client in
            try await client.selectPlaybackTracks(path: .init(sessionId: session), body: .json(selection)).ok.body.json
        }
        await loadCues()
    }

    /// The player refused the stream: the entry is marked bad and the next one plays.
    public func playerFailed(_ reason: String) async {
        guard let session = stream?.sessionId else { return }
        // A stream fetched at home fails when home is left.
        await endpoint.confirmHome(using: client, on: capabilities.facts().path, force: endpoint.atHome)
        let event = Components.Schemas.PlaybackEvent(
            kind: .clientFailure, positionMs: output.positionMs, reason: String(reason.prefix(500)))
        await update { client in
            try await client.reportPlaybackEvent(path: .init(sessionId: session), body: .json(event)).ok.body.json
        }
    }

    public func stalled() async {
        guard let session = stream?.sessionId else { return }
        let event = Components.Schemas.PlaybackEvent(kind: .stall, positionMs: output.positionMs)
        await update(telemetry: true) { client in
            try await client.reportPlaybackEvent(path: .init(sessionId: session), body: .json(event)).ok.body.json
        }
    }

    /// The ten-second report: throughput telemetry, which carries the position.
    public func tick() async {
        guard let session = stream?.sessionId else { return }
        var telemetry = await output.telemetry()
        telemetry.positionMs = output.positionMs
        rungInUse = telemetry.rungHeight.flatMap { height in
            telemetry.rungBitrate.map { RungInUse(height: height, bitrate: $0) }
        }
        await update(telemetry: true, positioned: true) { client in
            try await client.reportPlaybackThroughput(path: .init(sessionId: session), body: .json(telemetry)).ok.body
                .json
        }
        // A change already in flight is not sent twice.
        if !adjusting { for group in unsent { await capabilitiesChanged(group) } }
    }

    public func reportPosition() async {
        guard let session = stream?.sessionId else { return }
        _ = try? await client.reportPlaybackPosition(
            path: .init(sessionId: session),
            body: .json(.init(positionMs: output.positionMs, paused: output.isPaused))
        ).noContent
    }

    /// Another device took the session: the server ended it, so nothing is left to end or report.
    func taken() {
        stopped = true
        reporter?.cancel()
        output.stop()
        stream = nil
    }

    public func stop() async {
        stopped = true
        station?.cancel()
        await endSession()
    }

    func endSession() async {
        reporter?.cancel()
        guard let session = stream?.sessionId else { return }
        let position = output.positionMs
        output.stop()
        stream = nil
        _ = try? await client.endPlayback(path: .init(sessionId: session), query: .init(positionMs: position))
            .noContent
    }

    /// Sends one mid-playback message after recording where the player is,
    /// unless the message itself carries it, so a restart resumes at this
    /// exact position. Telemetry neither shows as adjusting nor surfaces its
    /// failures; playback carries on. The answer says whether it was sent.
    @discardableResult
    private func update(
        telemetry: Bool = false, positioned: Bool = false, surfacing: Bool = true,
        _ send: (Client) async throws -> Components.Schemas.PlaybackUpdate
    ) async -> Bool {
        if !telemetry { adjusting = true }
        defer { if !telemetry { adjusting = false } }
        if !positioned { await reportPosition() }
        do {
            let update = try await send(client)
            // An answer that lands after close must not bring the player back.
            guard !stopped else { return true }
            if update.action == .restart || endpoint.home.moved {
                await load(update.stream)
            } else {
                stream = update.stream
            }
            return true
        } catch {
            if !telemetry, surfacing { fail(error) }
            return false
        }
    }

    /// Sends each group that changed while the session was starting, since
    /// a change heard before the session existed had nowhere to go.
    private func catchUp(since sent: DeviceFacts) async {
        let now = capabilities.facts()
        if now.screen != sent.screen { await capabilitiesChanged(.display) }
        if now.route != sent.route { await capabilitiesChanged(.audioRoute) }
        if now.path != sent.path { await capabilitiesChanged(.network) }
    }

    /// A restart of a paused stream stays paused.
    private func load(_ stream: PlaybackStream) async {
        let paused = self.stream != nil && output.isPaused
        self.stream = stream
        rungInUse = nil
        output.load(stream, from: endpoint.resolveStream(stream.streamUrl))
        if !paused { output.play() }
        await loadCues()
        if stream.mediaFileId != file?.id {
            file = try? await client.getMediaFile(path: .init(mediaFileId: stream.mediaFileId)).ok.body.json
        }
    }

    private func loadCues() async {
        cues = []
        cueLoads += 1
        let mine = cueLoads
        guard subtitleChoice != .off, let stream else { return }
        let wanted: Components.Schemas.Sidecar?
        if case .track(let id) = subtitleChoice {
            wanted = stream.sidecars.first { $0.trackId == id }
        } else {
            wanted = stream.sidecars.first { $0.forced }
        }
        guard let sidecar = wanted, let text = try? await fetchText(endpoint.resolve(sidecar.url)), mine == cueLoads
        else { return }
        cues = SubtitleCue.parse(text)
    }

    private func effectiveQuality(in stream: PlaybackStream) -> QualityChoice {
        quality == .auto && stream.away != true ? .original : quality
    }

    /// Until the player reports a variant, the negotiated rung stands in.
    private func currentRung(in stream: PlaybackStream) -> RungInUse {
        rungInUse ?? RungInUse(height: stream.negotiated.height, bitrate: stream.negotiated.bitrate)
    }

    private func fail(_ error: any Error) {
        if APIError.from(error)?.status == 409 {
            self.error = "This title can't play on this \(device)."
        } else {
            self.error = AppError.from(error, unauthorized: .signedOut).localizedDescription
        }
    }
}
