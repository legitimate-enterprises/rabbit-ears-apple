import AVFoundation

/// AVPlayer as the music player's output, reporting failures and the end of each song.
@MainActor
public final class AVAudioOutput: AudioOutput {
    public let player = AVPlayer()
    public var onFailure: ((String) -> Void)?
    public var onEnd: (() -> Void)?
    public var onInterruption: ((AudioInterruption) -> Void)?
    public var onPlayingChange: (() -> Void)?
    private var statusObservation: NSKeyValueObservation?
    private var endObserver: (any NSObjectProtocol)?
    private let sessionObservers = ObserverTokens()
    private var playingObservation: NSKeyValueObservation?
    /// Where a seek in flight lands; see `AVPlayerOutput.seekingToMs`.
    private var seekingToMs: Int64?

    public init() {
        playingObservation = player.observe(\.timeControlStatus) { [weak self] _, _ in
            Task { @MainActor in self?.onPlayingChange?() }
        }
        #if os(iOS) || os(tvOS)
            let center = NotificationCenter.default
            guard #available(iOS 27, tvOS 27, *) else {
                // Posted only for the system's interruptions, never for the app's own deactivation.
                sessionObservers.tokens.append(
                    center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) {
                        [weak self] note in
                        let info = note.userInfo ?? [:]
                        let options = AVAudioSession.InterruptionOptions(
                            rawValue: info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
                        let event: AudioInterruption? =
                            switch info[AVAudioSessionInterruptionTypeKey] as? UInt {
                            case AVAudioSession.InterruptionType.began.rawValue: .began
                            case AVAudioSession.InterruptionType.ended.rawValue:
                                .ended(shouldResume: options.contains(.shouldResume))
                            default: nil
                            }
                        guard let event else { return }
                        MainActor.assumeIsolated { self?.onInterruption?(event) }
                    })
                return
            }
            // The system deactivates the session to interrupt it; the app's own deactivation is no interruption.
            sessionObservers.tokens.append(
                center.addObserver(forName: AVAudioSession.didBecomeInactiveNotification, object: nil, queue: .main) {
                    [weak self] note in
                    let context =
                        note.userInfo?[AVAudioSession.deactivationContextKey] as? AVAudioSession.DeactivationContext
                    guard context?.source == .system else { return }
                    MainActor.assumeIsolated { self?.onInterruption?(.began) }
                })
            sessionObservers.tokens.append(
                center.addObserver(
                    forName: AVAudioSession.resumptionRecommendationNotification, object: nil, queue: .main
                ) { [weak self] note in
                    let context =
                        note.userInfo?[AVAudioSession.resumptionContextKey] as? AVAudioSession.ResumptionContext
                    let resume = context?.recommendation == .shouldResume
                    MainActor.assumeIsolated { self?.onInterruption?(.ended(shouldResume: resume)) }
                })
        #endif
    }

    public func load(_ url: URL) {
        let item = AVPlayerItem(url: url)
        statusObservation = item.observe(\.status) { [weak self] item, _ in
            guard item.status == .failed else { return }
            let reason = item.error?.localizedDescription ?? "The player could not open the stream."
            Task { @MainActor in self?.onFailure?(reason) }
        }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.onEnd?() }
        }
        seekingToMs = nil
        player.replaceCurrentItem(with: item)
    }

    public func play() { player.play() }
    public func pause() { player.pause() }

    public func seek(toMs ms: Int64) {
        seekingToMs = ms
        player.seek(to: CMTime(value: ms, timescale: 1000), toleranceBefore: .zero, toleranceAfter: .zero) {
            [weak self] _ in
            Task { @MainActor in if self?.seekingToMs == ms { self?.seekingToMs = nil } }
        }
    }

    public func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        seekingToMs = nil
        statusObservation = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
    }

    public var positionMs: Int64 {
        if let seekingToMs { return seekingToMs }
        let seconds = player.currentTime().seconds
        return seconds.isFinite ? Int64(max(0, seconds) * 1000) : 0
    }

    public var isPaused: Bool { player.timeControlStatus == .paused }
    public var isPlaying: Bool { player.timeControlStatus == .playing }
}

/// Removes its notification observers when released, so an owner needs no
/// `isolated deinit`: that aborts in swift_task_deinitOnExecutor on tvOS 26.0.
final class ObserverTokens {
    var tokens: [any NSObjectProtocol] = []
    deinit { tokens.forEach(NotificationCenter.default.removeObserver) }
}
