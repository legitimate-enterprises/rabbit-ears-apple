import AVFoundation
import RabbitEarsAPI

extension VideoOutput {
    /// Loads a stream at its position, to hold the forward buffer the server names for it.
    func load(_ stream: PlaybackStream, from url: URL) {
        load(
            url, startingAt: Double(stream.positionMs) / 1000,
            bufferGoal: TimeInterval(stream.bufferGoalSeconds ?? 0))
    }
}

/// AVPlayer as the player's video output, reporting failures, stalls and
/// access-log throughput back to the model.
@MainActor
public final class AVPlayerOutput: VideoOutput {
    public let player = AVPlayer()
    public var onFailure: ((String) -> Void)?
    public var onStall: (() -> Void)?
    public var onEnd: (() -> Void)?
    private var statusObservation: NSKeyValueObservation?
    private var stallObserver: (any NSObjectProtocol)?
    private var endObserver: (any NSObjectProtocol)?
    private var stalls = 0
    /// A start waiting for its moment, or stall waiting to come back on after one.
    private var pending: Task<Void, Never>?
    /// Where a seek in flight lands. Until it does AVPlayer reports the time
    /// before it, or zero for an item not yet ready, and a report of that
    /// would restart or resume the stream there.
    private var seekingToMs: Int64?

    public init() {}

    public func load(_ url: URL, startingAt seconds: Double, bufferGoal: TimeInterval = 0) {
        let item = AVPlayerItem(url: url)
        // A preference: the system holds less than a long goal asks.
        item.preferredForwardBufferDuration = bufferGoal
        statusObservation = item.observe(\.status) { [weak self] item, _ in
            guard item.status == .failed else { return }
            let reason = item.error?.localizedDescription ?? "The player could not open the stream."
            Task { @MainActor in self?.onFailure?(reason) }
        }
        if let stallObserver { NotificationCenter.default.removeObserver(stallObserver) }
        stallObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.playbackStalledNotification, object: item, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.stalls += 1
                self?.onStall?()
            }
        }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.onEnd?() }
        }
        seekingToMs = nil
        player.replaceCurrentItem(with: item)
        if seconds > 0 { seek(toMs: Int64((seconds * 1000).rounded())) }
    }

    public func play() { player.play() }
    public func pause() {
        pending?.cancel()
        player.pause()
        player.automaticallyWaitsToMinimizeStalling = true
    }

    /// On the host clock once the item is ready and buffered, which takes
    /// stall waiting off for the call and a moment after it; otherwise a
    /// seek and play when the delay has passed.
    public func play(atMs ms: Int64, after delay: TimeInterval) {
        pending?.cancel()
        guard let item = player.currentItem, item.status == .readyToPlay, item.isPlaybackLikelyToKeepUp else {
            pending = Task { [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled, let self else { return }
                self.seek(toMs: ms)
                self.player.play()
            }
            return
        }
        player.automaticallyWaitsToMinimizeStalling = false
        let host = CMTimeAdd(
            CMClockGetTime(CMClockGetHostTimeClock()), CMTime(seconds: delay, preferredTimescale: 1_000_000_000))
        player.setRate(1, time: CMTime(value: ms, timescale: 1000), atHostTime: host)
        pending = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay + 1))
            self?.player.automaticallyWaitsToMinimizeStalling = true
        }
    }

    public func seek(toMs ms: Int64) {
        seekingToMs = ms
        player.seek(to: CMTime(value: ms, timescale: 1000), toleranceBefore: .zero, toleranceAfter: .zero) {
            [weak self] _ in
            Task { @MainActor in if self?.seekingToMs == ms { self?.seekingToMs = nil } }
        }
    }

    public func stop() {
        pending?.cancel()
        player.automaticallyWaitsToMinimizeStalling = true
        player.pause()
        player.replaceCurrentItem(with: nil)
        seekingToMs = nil
        statusObservation = nil
        if let stallObserver { NotificationCenter.default.removeObserver(stallObserver) }
        stallObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
    }

    public var positionMs: Int64 {
        if let seekingToMs { return seekingToMs }
        let seconds = player.currentTime().seconds
        return seconds.isFinite ? Int64(max(0, seconds) * 1000) : 0
    }

    public var isPaused: Bool { player.timeControlStatus == .paused }
    public var isBuffering: Bool { player.timeControlStatus == .waitingToPlayAtSpecifiedRate }

    public func telemetry() async -> Components.Schemas.ThroughputTelemetry {
        let item = player.currentItem
        let log: AVPlayerItemAccessLog?
        if #available(macOS 27, iOS 27, tvOS 27, *) {
            log = await withCheckedContinuation { done in
                guard let item else { return done.resume(returning: nil) }
                item.fetchAccessLog { done.resume(returning: $0) }
            }
        } else {
            log = item?.accessLog()
        }
        let now = player.currentTime().seconds
        let buffered =
            item?.loadedTimeRanges.map(\.timeRangeValue)
            .first { $0.start.seconds <= now && now <= $0.end.seconds }
            .map { $0.end.seconds - now } ?? 0
        let event = log?.events.last
        return Telemetry.sample(
            observedBitrate: event?.observedBitrate ?? 0, bufferSeconds: buffered, stalls: stalls,
            height: Double(item?.presentationSize.height ?? 0), indicatedBitrate: event?.indicatedBitrate ?? -1)
    }
}
