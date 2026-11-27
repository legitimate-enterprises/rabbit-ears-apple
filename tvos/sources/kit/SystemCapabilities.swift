import AVFoundation
import Network
import UIKit

@MainActor
@Observable
public final class SystemCapabilities: CapabilitySource {
    /// One slot, the player's; a screen observes `path` instead.
    public var onChange: ((CapabilityGroup) -> Void)?

    private let pathMonitor = NWPathMonitor()
    public private(set) var path = PathFacts()
    private let observers = ObserverTokens()

    public init() {
        pathMonitor.pathUpdateHandler = { [weak self] newPath in
            let facts = PathFacts(
                expensive: newPath.isExpensive, constrained: newPath.isConstrained,
                vpn: newPath.usesInterfaceType(.other))
            Task { @MainActor in
                guard let self, self.path != facts else { return }
                self.path = facts
                self.onChange?(.network)
            }
        }
        pathMonitor.start(queue: .main)
        let groups: [(Notification.Name, CapabilityGroup)] = [
            (UIScreen.modeDidChangeNotification, .display),
            (AVPlayer.eligibleForHDRPlaybackDidChangeNotification, .display),
            (AVAudioSession.routeChangeNotification, .audioRoute),
        ]
        for (name, group) in groups {
            observers.tokens.append(
                NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.onChange?(group) }
                })
        }
    }

    deinit { pathMonitor.cancel() }

    public func facts() -> DeviceFacts {
        let session = AVAudioSession.sharedInstance()
        var facts = DeviceFacts.decoder
        facts.screen = Self.screen.map {
            Self.screenFacts(
                nativeSize: $0.nativeBounds.size, refreshRate: $0.maximumFramesPerSecond,
                hdr: AVPlayer.eligibleForHDRPlayback)
        }
        facts.route = Self.routeFacts(channels: session.maximumOutputNumberOfChannels, sampleRate: session.sampleRate)
        facts.path = path
        return facts
    }

    /// HDR eligibility, which covers the attached display, stands in for EDR
    /// headroom, which a TV reports only while its output is already HDR.
    public static func screenFacts(nativeSize: CGSize, refreshRate: Int, hdr: Bool) -> ScreenFacts {
        ScreenFacts(
            width: Int(nativeSize.width), height: Int(nativeSize.height), refreshRate: Double(refreshRate),
            edrHeadroom: hdr ? 2 : 1)
    }

    /// The session exposes no encoded formats, so nothing passes through;
    /// a receiver shows as its channel count.
    public static func routeFacts(channels: Int, sampleRate: Double) -> RouteFacts {
        RouteFacts(channels: channels, maxSampleRate: sampleRate > 0 ? Int(sampleRate) : nil)
    }

    private static var screen: UIScreen? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return (scenes.first { $0.activationState == .foregroundActive } ?? scenes.first)?.screen
    }
}
