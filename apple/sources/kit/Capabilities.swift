import AVFoundation
import AudioToolbox
import Foundation
import RabbitEarsAPI
import VideoToolbox

public typealias CapabilitySnapshot = Components.Schemas.CapabilitySnapshot

/// The raw OS facts a snapshot is built from, kept apart so the mapping is
/// testable without the hardware.
public struct DeviceFacts: Equatable, Sendable {
    /// ffprobe codec names VideoToolbox decodes in hardware.
    public var hardwareVideoCodecs: Set<String>
    /// The Simulator, which has no hardware decoders, plays H.264 in software.
    public var softwareH264: Bool
    public var hdrPlayback: Bool
    public var audioDecoders: [AudioFormatID]
    /// Uniform type identifiers AVFoundation opens as a plain file.
    public var playableTypes: [String]
    public var screen: ScreenFacts?
    public var route: RouteFacts
    public var path: PathFacts
    /// The hardware model identifier, such as `AppleTV5,3`; a simulator or a Mac reports its CPU architecture.
    public var model: String

    public init(
        hardwareVideoCodecs: Set<String>, hdrPlayback: Bool, audioDecoders: [AudioFormatID], playableTypes: [String],
        screen: ScreenFacts?, route: RouteFacts, path: PathFacts, model: String = "", softwareH264: Bool = false
    ) {
        self.hardwareVideoCodecs = hardwareVideoCodecs
        self.softwareH264 = softwareH264
        self.hdrPlayback = hdrPlayback
        self.audioDecoders = audioDecoders
        self.playableTypes = playableTypes
        self.screen = screen
        self.route = route
        self.path = path
        self.model = model
    }
}

extension DeviceFacts {
    /// Group A, probed once per launch; each platform's `CapabilitySource`
    /// reads the other groups and `hdrPlayback` again.
    public static let decoder: DeviceFacts = {
        let codecs: [(String, CMVideoCodecType)] = [
            ("h264", kCMVideoCodecType_H264), ("hevc", kCMVideoCodecType_HEVC), ("av1", kCMVideoCodecType_AV1),
        ]
        let video = Set(codecs.filter { VTIsHardwareDecodeSupported($0.1) }.map(\.0))
        var size: UInt32 = 0
        var audio: [AudioFormatID] = []
        if AudioFormatGetPropertyInfo(kAudioFormatProperty_DecodeFormatIDs, 0, nil, &size) == noErr {
            audio = [AudioFormatID](repeating: 0, count: Int(size) / MemoryLayout<AudioFormatID>.size)
            if AudioFormatGetProperty(kAudioFormatProperty_DecodeFormatIDs, 0, nil, &size, &audio) != noErr {
                audio = []
            }
        }
        var name = utsname()
        uname(&name)
        let model = withUnsafeBytes(of: name.machine) { String(bytes: $0.prefix { $0 != 0 }, encoding: .ascii) } ?? ""
        return DeviceFacts(
            hardwareVideoCodecs: video, hdrPlayback: AVPlayer.eligibleForHDRPlayback, audioDecoders: audio,
            playableTypes: AVURLAsset.audiovisualContentTypes.map(\.identifier), screen: nil,
            route: RouteFacts(channels: 2), path: PathFacts(), model: model,
            softwareH264: simulator)
    }()

    private static var simulator: Bool {
        #if targetEnvironment(simulator)
            true
        #else
            false
        #endif
    }
}

public struct ScreenFacts: Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var refreshRate: Double
    /// Extended dynamic range headroom; above 1 means the screen shows HDR.
    public var edrHeadroom: Double

    public init(width: Int, height: Int, refreshRate: Double, edrHeadroom: Double) {
        self.width = width
        self.height = height
        self.refreshRate = refreshRate
        self.edrHeadroom = edrHeadroom
    }
}

public struct RouteFacts: Equatable, Sendable {
    public var channels: Int
    /// Formats the output device's streams accept, including encoded bitstreams.
    public var physicalFormats: [AudioFormatID]
    public var maxSampleRate: Int?

    public init(channels: Int, physicalFormats: [AudioFormatID] = [], maxSampleRate: Int? = nil) {
        self.channels = channels
        self.physicalFormats = physicalFormats
        self.maxSampleRate = maxSampleRate
    }
}

public struct PathFacts: Equatable, Sendable {
    public var expensive = false
    public var constrained = false
    public var vpn = false

    public init(expensive: Bool = false, constrained: Bool = false, vpn: Bool = false) {
        self.expensive = expensive
        self.constrained = constrained
        self.vpn = vpn
    }
}

/// The capability group a change on this device invalidates.
public enum CapabilityGroup: Sendable { case display, audioRoute, network }

/// Where the player gets the current facts and hears when they change.
@MainActor
public protocol CapabilitySource: AnyObject {
    func facts() -> DeviceFacts
    var onChange: ((CapabilityGroup) -> Void)? { get set }
}

/// Maps OS facts to the server's capability groups.
public enum CapabilitySnapshotBuilder {
    /// Codec limits VideoToolbox does not report: the highest level each
    /// codec defines on Apple silicon. An optimistic limit costs one client
    /// failure, which moves the plan to its next entry.
    struct VideoLimit {
        let codec: String
        let profiles: [String]
        let level: Int?
        let width: Int
        let height: Int
        let depth: Int
        var frameRate: Double = 120
    }

    static let videoLimits = [
        VideoLimit(
            codec: "h264", profiles: ["Constrained Baseline", "Baseline", "Main", "High"], level: 52, width: 4096,
            height: 2304, depth: 8),
        VideoLimit(codec: "hevc", profiles: ["Main", "Main 10"], level: 186, width: 8192, height: 4320, depth: 10),
        VideoLimit(codec: "av1", profiles: ["Main"], level: nil, width: 8192, height: 4320, depth: 10),
    ]

    /// Hardware model identifiers whose decoder falls short of `videoLimits`,
    /// from Apple's published video formats for the model.
    static let modelVideoLimits = [
        // Apple TV HD, support.apple.com/111928.
        "AppleTV5,3": [
            VideoLimit(
                codec: "h264", profiles: ["Main", "High"], level: 42, width: 1920, height: 1080, depth: 8,
                frameRate: 60),
            VideoLimit(
                codec: "hevc", profiles: ["Main", "Main 10"], level: nil, width: 1920, height: 1080, depth: 10,
                frameRate: 30),
        ]
    ]

    static let audioNames: [AudioFormatID: String] = [
        kAudioFormatMPEG4AAC: "aac", kAudioFormatAC3: "ac3", kAudioFormatEnhancedAC3: "eac3", kAudioFormatFLAC: "flac",
        kAudioFormatOpus: "opus", kAudioFormatAppleLossless: "alac", kAudioFormatMPEGLayer3: "mp3",
    ]

    static let passthroughNames: [AudioFormatID: String] = [
        kAudioFormatAC3: "ac3", kAudioFormat60958AC3: "ac3", kAudioFormatEnhancedAC3: "eac3",
    ]

    static let containerNames: [(type: String, name: String)] = [
        ("public.mpeg-4", "mp4"), ("com.apple.m4v-video", "mp4"), ("com.apple.quicktime-movie", "mov"),
    ]

    static let hdrFormats: [Components.Schemas.HdrFormat] = [.hdr10, .hlg, .dolbyVision]

    public static func snapshot(
        _ facts: DeviceFacts, server: ServerEndpoint, maxBitrate: Int64?, auto: Bool = false
    ) -> CapabilitySnapshot {
        .init(
            decoder: decoder(facts), display: display(facts.screen), audioRoute: audioRoute(facts.route),
            network: network(facts.path, server: server, maxBitrate: maxBitrate, auto: auto))
    }

    public static func decoder(_ facts: DeviceFacts) -> Components.Schemas.DecoderCapabilities {
        let limits = modelVideoLimits[facts.model] ?? videoLimits
        var video = limits.filter { facts.hardwareVideoCodecs.contains($0.codec) }.map { limit in
            Components.Schemas.VideoDecoder(
                codec: limit.codec, profiles: limit.profiles, maxLevel: limit.level, hardware: true,
                maxWidth: limit.width, maxHeight: limit.height, maxFrameRate: limit.frameRate, maxBitDepth: limit.depth,
                hdrFormats: facts.hdrPlayback && limit.depth > 8 ? hdrFormats : [])
        }
        // Never played directly: the server only converts to a software decoder, within this size.
        if facts.softwareH264 && !facts.hardwareVideoCodecs.contains("h264") {
            video.append(
                .init(
                    codec: "h264", hardware: false, maxWidth: 1920, maxHeight: 1080, maxFrameRate: 30,
                    maxBitDepth: 8, hdrFormats: []))
        }
        var containers: [String] = []
        for (type, name) in containerNames where facts.playableTypes.contains(type) && !containers.contains(name) {
            containers.append(name)
        }
        var audio: [String] = []
        for id in facts.audioDecoders { if let name = audioNames[id], !audio.contains(name) { audio.append(name) } }
        return .init(
            protocols: [.http, .hls], containers: containers, videoCodecs: video, audioCodecs: audio,
            subtitleFormats: ["webvtt", "srt"])
    }

    /// Without a screen (a headless session) the answer is a 1080p SDR display.
    public static func display(_ screen: ScreenFacts?) -> Components.Schemas.DisplayCapabilities {
        guard let screen, screen.width > 0, screen.height > 0 else {
            return .init(width: 1920, height: 1080, refreshRate: 60, hdrFormats: [])
        }
        return .init(
            width: screen.width, height: screen.height, refreshRate: screen.refreshRate > 0 ? screen.refreshRate : 60,
            hdrFormats: screen.edrHeadroom > 1 ? hdrFormats : [])
    }

    public static func audioRoute(_ route: RouteFacts) -> Components.Schemas.AudioRouteCapabilities {
        var passthrough: [String] = []
        for id in route.physicalFormats {
            if let name = passthroughNames[id], !passthrough.contains(name) { passthrough.append(name) }
        }
        return .init(
            channels: route.channels < 1 ? 2 : min(16, route.channels),
            passthroughCodecs: passthrough, maxSampleRate: route.maxSampleRate.flatMap { $0 >= 8000 ? $0 : nil })
    }

    public static func network(
        _ path: PathFacts, server: ServerEndpoint, maxBitrate: Int64?, auto: Bool = false
    ) -> Components.Schemas.NetworkPathCapabilities {
        // auto is always sent: the server treats a snapshot without it as a v1 client.
        .init(
            discoveredLocally: server.atHome, metered: path.expensive, lowData: path.constrained,
            vpn: path.vpn, auto: auto, maxBitrate: maxBitrate)
    }
}
