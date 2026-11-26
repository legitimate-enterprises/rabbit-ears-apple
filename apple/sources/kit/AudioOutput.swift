import Foundation

/// What plays the music; AVPlayer in the apps, a recorder in tests.
@MainActor
public protocol AudioOutput: AnyObject {
    func load(_ url: URL)
    func play()
    func pause()
    func seek(toMs ms: Int64)
    func stop()
    var positionMs: Int64 { get }
    var isPaused: Bool { get }
    /// The audio is advancing. AVPlayer's rate stays at the one asked for while it waits or the system holds it.
    var isPlaying: Bool { get }
    /// `isPlaying` changed, as when the system pauses the output or a stream starts after buffering.
    var onPlayingChange: (() -> Void)? { get set }
    var onFailure: ((String) -> Void)? { get set }
    var onEnd: (() -> Void)? { get set }
    var onInterruption: ((AudioInterruption) -> Void)? { get set }
}

/// A call, Siri or another app taking the audio session, which pauses the output, and the system giving it back.
public enum AudioInterruption: Equatable, Sendable {
    case began
    case ended(shouldResume: Bool)
}
