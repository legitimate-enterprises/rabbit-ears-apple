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
}
