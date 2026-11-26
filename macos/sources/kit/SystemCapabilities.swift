import AppKit
import AudioToolbox
import CoreAudio
import Network

/// Reads capability facts from AVFoundation, VideoToolbox, NSScreen,
/// CoreAudio and Network, and reports screen, audio route and path changes.
@MainActor
@Observable
public final class SystemCapabilities: CapabilitySource {
    /// One slot, the player's; a screen observes `path` instead.
    public var onChange: ((CapabilityGroup) -> Void)?

    private let pathMonitor = NWPathMonitor()
    public private(set) var path = PathFacts()
    private var observers: [any NSObjectProtocol] = []
    private var routeListener: AudioObjectPropertyListenerBlock?

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
        for name in [NSApplication.didChangeScreenParametersNotification, NSWindow.didChangeScreenNotification] {
            observers.append(
                NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.onChange?(.display) }
                })
        }
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.onChange?(.audioRoute) }
        }
        var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
        routeListener = listener
    }

    isolated deinit {
        pathMonitor.cancel()
        observers.forEach(NotificationCenter.default.removeObserver)
        if let routeListener {
            var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, .main, routeListener)
        }
    }

    public func facts() -> DeviceFacts {
        Self.readFacts(path: path)
    }

    public static func readFacts(screen: NSScreen? = NSScreen.main, path: PathFacts = PathFacts()) -> DeviceFacts {
        var facts = DeviceFacts.decoder
        facts.screen = screen.map(screenFacts)
        facts.route = routeFacts()
        facts.path = path
        return facts
    }

    static func screenFacts(_ screen: NSScreen) -> ScreenFacts {
        let scale = screen.backingScaleFactor
        return ScreenFacts(
            width: Int(screen.frame.width * scale), height: Int(screen.frame.height * scale),
            refreshRate: Double(screen.maximumFramesPerSecond),
            edrHeadroom: Double(screen.maximumPotentialExtendedDynamicRangeColorComponentValue))
    }

    /// The default output device's channel count, accepted stream formats
    /// and highest sample rate. No device reads as stereo PCM.
    static func routeFacts() -> RouteFacts {
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard let device: AudioObjectID = read(system, kAudioHardwarePropertyDefaultOutputDevice).first,
            device != kAudioObjectUnknown
        else { return RouteFacts(channels: 2) }

        var address = address(kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeOutput)
        var size: UInt32 = 0
        var channels = 0
        if AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 {
            let raw = UnsafeMutableRawPointer.allocate(
                byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
            defer { raw.deallocate() }
            if AudioObjectGetPropertyData(device, &address, 0, nil, &size, raw) == noErr {
                let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
                channels = list.reduce(0) { $0 + Int($1.mNumberChannels) }
            }
        }
        let streams: [AudioStreamID] = read(device, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput)
        let formats = streams.flatMap { stream -> [AudioFormatID] in
            let ranged: [AudioStreamRangedDescription] = read(stream, kAudioStreamPropertyAvailablePhysicalFormats)
            return ranged.map(\.mFormat.mFormatID)
        }
        let rates: [AudioValueRange] = read(device, kAudioDevicePropertyAvailableNominalSampleRates)
        let maxRate = rates.map(\.mMaximum).max().map { Int($0) }
        return RouteFacts(channels: channels, physicalFormats: formats, maxSampleRate: maxRate)
    }

    nonisolated static func address(
        _ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func read<T>(
        _ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> [T] {
        var address = address(selector, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<T>.stride
        return [T](unsafeUninitializedCapacity: count) { buffer, initialized in
            let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, buffer.baseAddress!)
            initialized = status == noErr ? Int(size) / MemoryLayout<T>.stride : 0
        }
    }
}
