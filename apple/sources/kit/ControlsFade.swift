import AVFoundation
import SwiftUI

/// How a player's controls leave once there is no activity: they start
/// fading after `delay` seconds (`remoteDelay` on a remote, which is slower
/// than a pointer) and are gone `fade` seconds later. Gone means out of the
/// hierarchy, so nothing unseen takes a click, a tap, focus or VoiceOver.
public enum ControlsFade {
    public static let delay = 2.0
    public static let remoteDelay = 3.0
    public static let fade = 1.0
    public static let animation = Animation.easeOut(duration: fade)

    /// True once `player` is still playing `delay` seconds after it was
    /// found playing, however long playback takes to start or resume, and
    /// whatever starts it; false once the task is cancelled.
    @MainActor
    public static func idle(_ player: AVPlayer, for delay: Double) async -> Bool {
        // Buffered, so a change that comes between two waits is not lost.
        let (changes, changed) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let observation = player.observe(\.timeControlStatus, options: .initial) { _, _ in changed.yield() }
        defer { observation.invalidate() }
        var waiting = changes.makeAsyncIterator()
        while await waiting.next() != nil {
            guard player.timeControlStatus == .playing else { continue }
            try? await Task.sleep(for: .seconds(delay))
            if !Task.isCancelled, player.timeControlStatus == .playing { return true }
        }
        return false
    }
}
