import AVFoundation
import Network
import UIKit

/// Reports screen, audio route and network path changes. Metered is the
/// path's `isExpensive`, low data its `isConstrained`.
@MainActor
@Observable
public final class SystemCapabilities: CapabilitySource {
    /// One slot, the player's; a screen observes `path` instead.
    public var onChange: ((CapabilityGroup) -> Void)?

    private let pathMonitor = NWPathMonitor()
    public private(set) var path = PathFacts()
    private var observers: [any NSObjectProtocol] = []

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
            (UIScreen.modeDidChangeNotification, .display), (AVAudioSession.routeChangeNotification, .audioRoute),
        ]
        for (name, group) in groups {
            observers.append(
                NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.onChange?(group) }
                })
        }
    }

    isolated deinit {
        pathMonitor.cancel()
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    public func facts() -> DeviceFacts {
        let session = AVAudioSession.sharedInstance()
        return Self.readFacts(
            screen: Self.screen.map {
                Self.screenFacts(
                    nativeSize: $0.nativeBounds.size, refreshRate: $0.maximumFramesPerSecond,
                    edrHeadroom: $0.potentialEDRHeadroom)
            },
            route: Self.routeFacts(channels: session.maximumOutputNumberOfChannels, sampleRate: session.sampleRate),
            path: path)
    }

    /// The AirPlay receiver playing the audio, which is then the stream's
    /// destination; nil when it plays on this iPhone.
    public var airPlayName: String? {
        AVAudioSession.sharedInstance().currentRoute.outputs.first { $0.portType == .airPlay }?.portName
    }

    public static func readFacts(screen: ScreenFacts?, route: RouteFacts, path: PathFacts) -> DeviceFacts {
        var facts = DeviceFacts.decoder
        // It follows the display, which can change while the app runs.
        facts.hdrPlayback = AVPlayer.eligibleForHDRPlayback
        facts.screen = screen
        facts.route = route
        facts.path = path
        return facts
    }

    /// Landscape pixels, since video plays sideways: the long side is the
    /// width whichever way the phone is held.
    public static func screenFacts(nativeSize: CGSize, refreshRate: Int, edrHeadroom: CGFloat) -> ScreenFacts {
        ScreenFacts(
            width: Int(max(nativeSize.width, nativeSize.height)), height: Int(min(nativeSize.width, nativeSize.height)),
            refreshRate: Double(refreshRate), edrHeadroom: Double(edrHeadroom))
    }

    /// The session exposes no encoded formats, so nothing passes through;
    /// over AirPlay the channels are what the receiver accepts.
    public static func routeFacts(channels: Int, sampleRate: Double) -> RouteFacts {
        RouteFacts(channels: channels, maxSampleRate: sampleRate > 0 ? Int(sampleRate) : nil)
    }

    /// The screen of the foreground scene, which is the one the player is on.
    private static var screen: UIScreen? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return (scenes.first { $0.activationState == .foregroundActive } ?? scenes.first)?.screen
    }
}

/// The quality menu's first line: what limits the stream away from home,
/// or where it plays at home.
public enum QualityHeading {
    public static func text(away: Bool, path: PathFacts, airPlay: String?) -> String {
        if path.constrained { return "Low Data Mode, up to 1.5 Mb/s" }
        if path.expensive { return "On cellular, up to 4 Mb/s" }
        if away { return "Away from home" }
        return "Playing on \(airPlay ?? "this iPhone")"
    }
}
