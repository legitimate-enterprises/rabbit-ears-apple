import Foundation
import Observation
import RabbitEarsAPI

/// The music engine. It needs no view: the apps, the lock screen and
/// CarPlay all drive the same one. Each song is its own playback session,
/// started with the device's snapshot; the server picks the quality.
@MainActor
@Observable
public final class MusicPlayer {
    /// Queued songs that fail in a row before playback stops.
    static let failureLimit = 3

    public private(set) var queue = AudioQueue()
    public private(set) var stream: PlaybackStream?
    public private(set) var playing = false
    /// The music station tuned in to; while set it picks every song and the queue waits.
    public private(set) var station: StationTuner?
    /// One line for an alert with OK; the view clears it.
    public var alert: String?

    private let client: Client
    private let endpoint: ServerEndpoint
    private let profileId: UID
    private let output: any AudioOutput
    private let capabilities: any CapabilitySource
    private let activateSession: @MainActor () -> Void
    private var center: (any NowPlayingCenter)?
    private var reporter: Task<Void, Never>?
    /// Whether the song playing was chosen rather than reached by the queue.
    private var picked = false
    private var failures = 0
    private var interruptedWhilePlaying = false
    /// Rises with every start, so an answer to an older one is dropped.
    private var attempt = 0
    /// Up next's order when shuffled; random but in tests.
    var shuffleOrder: ([AudioQueue.Entry]) -> [AudioQueue.Entry] = { $0.shuffled() }

    public init(
        client: Client, endpoint: ServerEndpoint, profileId: UID, output: any AudioOutput,
        capabilities: any CapabilitySource, activateSession: @escaping @MainActor () -> Void = AudioSession.activate
    ) {
        self.client = client
        self.endpoint = endpoint
        self.profileId = profileId
        self.output = output
        self.capabilities = capabilities
        self.activateSession = activateSession
        output.onFailure = { [weak self] reason in Task { await self?.outputFailed(reason) } }
        output.onEnd = { [weak self] in Task { await self?.songEnded() } }
        output.onInterruption = { [weak self] event in Task { await self?.interrupted(event) } }
        // Between songs there is no stream, and Now Playing stays up for the next.
        output.onPlayingChange = { [weak self] in if self?.stream != nil { self?.publish() } }
    }

    public var current: MusicSong? {
        if let station { return station.station.onAir.now?.song }
        return queue.current?.song
    }
    public var positionMs: Int64 { stream == nil ? 0 : output.positionMs }

    public func attach(_ center: any NowPlayingCenter) {
        self.center = center
        center.onCommand = { [weak self] command in Task { await self?.handle(command) } }
        publish()
    }

    /// While a video or a station is open the system's transport is not the
    /// music's: commands go unanswered and Now Playing is empty until `attach`.
    public func detach() {
        center?.onCommand = nil
        center?.show(nil)
        center = nil
    }

    /// Replaces the queue and plays from `start`. Shuffled, a song picked at random plays first.
    public func play(
        _ songs: [MusicSong], from start: Int = 0, source: String, playlistId: UID? = nil, shuffled: Bool = false
    ) async {
        var queue = AudioQueue(songs, start: start, source: source, playlistId: playlistId, shuffled: shuffled)
        queue.repeatMode = self.queue.repeatMode
        await begin(queue, picked: true, replacing: true)
    }

    /// A station cannot pause, so pausing one, as a video starting does, leaves it.
    public func pause() async {
        interruptedWhilePlaying = false
        if station != nil { return await leaveStation() }
        guard stream != nil, playing else { return }
        output.pause()
        playing = false
        publish()
        try? await reportPosition()
    }

    /// Resumes, or after failures stopped playback starts the queue's song
    /// again. The server ends a paused song's session, and its stream, when a
    /// video starts on the device or 30 minutes pass with no report; the song
    /// then starts a new session where it stood.
    public func resume() async {
        if let station { return await retune(station) }
        guard let session = stream?.sessionId else {
            if queue.current != nil { await begin(queue, picked: true) }
            return
        }
        var ended = false
        do { try await reportPosition() } catch { ended = APIError.from(error)?.status == 404 }
        guard stream?.sessionId == session else { return }
        if ended { return await begin(queue, picked: true, at: output.positionMs) }
        activateSession()
        output.play()
        playing = true
        publish()
    }

    public func toggle() async { playing ? await pause() : await resume() }

    public func seek(toMs ms: Int64) {
        guard stream != nil else { return }
        output.seek(toMs: max(0, ms))
        publish()
    }

    public func next() async {
        var queue = queue
        guard queue.next(auto: false) else { return await stop() }
        await begin(queue, picked: true)
    }

    /// Past the first 3 seconds, or with nothing before, the song restarts.
    public func previous() async {
        var queue = queue
        let before = queue.index
        queue.previous()
        guard output.positionMs <= 3000, queue.index != before else { return seek(toMs: 0) }
        await begin(queue, picked: true)
    }

    public func jump(to id: AudioQueue.Entry.ID) async {
        var queue = queue
        guard queue.jump(to: id) else { return }
        await begin(queue, picked: true)
    }

    public func setShuffle(_ on: Bool) {
        queue.setShuffle(on, order: shuffleOrder)
        publish()
    }

    public func setRepeat(_ mode: RepeatMode) {
        queue.repeatMode = mode
        publish()
    }

    public func moveUpNext(fromOffsets source: IndexSet, toOffset destination: Int) {
        queue.moveUpNext(fromOffsets: source, toOffset: destination)
    }

    public func removeFromUpNext(_ id: AudioQueue.Entry.ID) { queue.remove(id) }
    public func clearUpNext() { queue.clearUpNext() }

    /// Ends playback, a station's too, and empties the queue, so the mini player and Now Playing go.
    public func stop() async {
        queue = AudioQueue()
        await leaveStation()
    }

    /// A station takes only stop.
    public func handle(_ command: RemoteCommand) async {
        if station == nil {
            await perform(command)
        } else if command == .stop {
            await leaveStation()
        }
    }

    private func perform(_ command: RemoteCommand) async {
        switch command {
        case .play: await resume()
        case .pause: await pause()
        case .toggle: await toggle()
        case .next: await next()
        case .previous: await previous()
        case .seek(let ms): seek(toMs: ms)
        case .shuffle(let on): setShuffle(on)
        case .repeatMode(let mode): setRepeat(mode)
        case .stop: await pause()
        }
    }

    /// The ten-second report: keeps the profile's Recently played and the server's session current.
    public func tick() async {
        try? await reportPosition()
        publish()
    }

    /// The system has already paused the output; this keeps `playing` and
    /// the lock screen true to it. Only what the listener had playing, and
    /// did not pause meanwhile, resumes, and only when the system says to.
    func interrupted(_ event: AudioInterruption) async {
        guard stream != nil else { return }
        switch event {
        case .began:
            interruptedWhilePlaying = playing
            playing = false
            publish()
        case .ended(let shouldResume):
            let wasPlaying = interruptedWhilePlaying
            interruptedWhilePlaying = false
            if shouldResume && wasPlaying { await resume() }
        }
    }

    func songEnded() async {
        if let station { return await retune(station) }
        failures = 0
        await endSession()
        var queue = queue
        guard queue.next(auto: true) else { return await stop() }
        await begin(queue, picked: false)
    }

    /// The player refused the stream: the server marks the entry bad and
    /// answers with the next; with none left the song cannot play.
    func outputFailed(_ reason: String) async {
        guard let session = stream?.sessionId, let song = current else { return }
        // A stream fetched at home fails when home is left.
        await endpoint.confirmHome(using: client, on: capabilities.facts().path, force: endpoint.atHome)
        let event = Components.Schemas.PlaybackEvent(
            kind: .clientFailure, positionMs: output.positionMs, reason: reason.prefix(scalars: 500))
        do {
            let update = try await client.reportPlaybackEvent(path: .init(sessionId: session), body: .json(event))
                .ok.body.json
            guard stream?.sessionId == session else { return }
            if update.action == .restart || endpoint.home.moved { load(update.stream) } else { stream = update.stream }
        } catch {
            guard stream?.sessionId == session else { return }
            if station != nil {
                alert = "\u{201C}\(song.title)\u{201D} can\u{2019}t be played"
                return await leaveStation()
            }
            await finish()
            // With the server out of reach the song stays current, for play to start it again.
            guard APIError.from(error) != nil else { return }
            await cannotPlay(song, in: queue, picked: picked)
        }
    }

    /// Starts the queue's current song in a new session while the song
    /// playing carries on, so a chosen one that cannot play leaves it. Unless
    /// `replacing`, the queue only moves to it, keeping edits made meanwhile.
    private func begin(_ candidate: AudioQueue, picked: Bool, replacing: Bool = false, at positionMs: Int64 = 0) async {
        guard let entry = candidate.current else { return }
        attempt += 1
        let mine = attempt
        if picked { failures = 0 }
        activateSession()
        let request = await Components.Schemas.PlaybackRequest(
            profileId: profileId, itemId: entry.song.id, positionMs: positionMs, playlistId: candidate.playlistId,
            snapshot: endpoint.snapshot(capabilities.facts(), checkedWith: client, maxBitrate: nil))
        let started = try? await client.startPlayback(body: .json(request)).created.body.json
        guard mine == attempt else {
            if let started { await end(started.sessionId, at: 0) }
            return
        }
        guard let started else { return await cannotPlay(entry.song, in: candidate, picked: picked) }
        await endSession()
        // A stop or a newer start while the old session ended wins.
        guard mine == attempt else { return await end(started.sessionId, at: 0) }
        station?.cancel()
        station = nil
        if replacing || !queue.settle(on: entry.id, from: candidate, order: shuffleOrder) { queue = candidate }
        self.picked = picked
        load(started)
    }

    /// A chosen song alerts once. A queued one is skipped silently until
    /// `failureLimit` in a row stop playback with one alert.
    private func cannotPlay(_ song: MusicSong, in candidate: AudioQueue, picked: Bool) async {
        if picked {
            alert = "\u{201C}\(song.title)\u{201D} can\u{2019}t be played"
            return
        }
        failures += 1
        var next = candidate
        guard failures < Self.failureLimit, next.next(auto: false) else {
            if failures >= Self.failureLimit { alert = "These songs can\u{2019}t be played" }
            failures = 0
            return await finish()
        }
        await begin(next, picked: false)
    }

    private func load(_ started: PlaybackStream) {
        stream = started
        output.load(endpoint.resolveStream(started.streamUrl))
        if started.positionMs > 0 { output.seek(toMs: started.positionMs) }
        output.play()
        playing = true
        publish()
        reporter?.cancel()
        reporter = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard let self, !Task.isCancelled else { return }
                await self.tick()
            }
        }
    }

    private func finish() async {
        await endSession()
        output.stop()
        playing = false
        publish()
    }

    private func endSession() async {
        reporter?.cancel()
        guard let session = stream?.sessionId else { return }
        let position = output.positionMs
        stream = nil
        await end(session, at: position)
    }

    private func end(_ session: UID, at position: Int64) async {
        _ = try? await client.endPlayback(path: .init(sessionId: session), query: .init(positionMs: position))
            .noContent
    }

    private func reportPosition() async throws {
        guard let session = stream?.sessionId else { return }
        _ = try await client.reportPlaybackPosition(
            path: .init(sessionId: session), body: .json(.init(positionMs: output.positionMs, paused: !playing))
        ).noContent
    }

    private func publish() {
        guard let center else { return }
        guard stream != nil, let song = current else { return center.show(nil) }
        center.show(
            NowPlayingInfo(
                title: song.title, artist: song.artistName, album: song.albumTitle, artworkItemId: song.albumId,
                durationMs: song.durationMs, elapsedMs: output.positionMs, playing: output.isPlaying,
                shuffled: queue.shuffled, repeatMode: queue.repeatMode, stopOnly: station != nil))
    }
}

extension MusicPlayer {
    /// The queue is left as it was, for when the station is stopped.
    public func tune(_ tuner: StationTuner) async {
        station?.cancel()
        station = tuner
        tuner.onWake = { [weak self, weak tuner] in
            guard let tuner else { return }
            await self?.retune(tuner)
        }
        await retune(tuner)
    }

    /// Stop: ends the station's session; the viewer's own queue is current again.
    public func leaveStation() async {
        attempt += 1
        station?.cancel()
        station = nil
        await finish()
    }

    /// Ends the session playing and plays what the station has on now at
    /// its live position; off the air nothing plays until the tuner wakes it.
    func retune(_ tuner: StationTuner) async {
        guard station === tuner else { return }
        attempt += 1
        let mine = attempt
        activateSession()
        await endSession()
        let snapshot = await endpoint.snapshot(capabilities.facts(), checkedWith: client, maxBitrate: nil)
        do {
            let started = try await tuner.ask(.init(snapshot: snapshot))
            guard mine == attempt, station === tuner else {
                if let started { await end(started.sessionId, at: 0) }
                return
            }
            guard let started else {
                output.stop()
                playing = false
                return publish()
            }
            load(started)
        } catch {
            guard mine == attempt else { return }
            alert = AppError.from(error, unauthorized: .signedOut).localizedDescription
            await leaveStation()
        }
    }
}
