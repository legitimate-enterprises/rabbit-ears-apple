import Foundation
import MediaPlayer
import RabbitEarsAPI

#if os(iOS) || os(tvOS)
    import AVFoundation
    import UIKit
#else
    import AppKit
#endif

/// What the lock screen, Control Center and CarPlay show for the song playing.
public struct NowPlayingInfo: Equatable, Sendable {
    public let title: String
    public let artist: String
    public let album: String
    /// The item whose artwork stands for the song: its album.
    public let artworkItemId: UID
    public let durationMs: Int64?
    public let elapsedMs: Int64
    public let playing: Bool
    public let shuffled: Bool
    public let repeatMode: RepeatMode
    /// A station: the system offers only stop.
    public let stopOnly: Bool
}

/// The system's transport buttons, from the lock screen, a headset or the car.
public enum RemoteCommand: Equatable, Sendable {
    case play, pause, toggle, next, previous, stop
    case seek(ms: Int64)
    case shuffle(Bool)
    case repeatMode(RepeatMode)
}

/// Where the music player publishes Now Playing and hears remote commands.
/// iOS, tvOS and the CarPlay scene attach the system one; tests attach a recorder.
@MainActor
public protocol NowPlayingCenter: AnyObject {
    func show(_ info: NowPlayingInfo?)
    var onCommand: ((RemoteCommand) -> Void)? { get set }
}

/// The audio session as music needs it. Activated at play, never at
/// launch, so opening the app never interrupts other audio.
public enum AudioSession {
    @MainActor
    public static func activate() {
        #if os(iOS) || os(tvOS)
            let session = AVAudioSession.sharedInstance()
            try? session.setCategory(.playback, mode: .default)
            try? session.setActive(true)
        #endif
    }
}

/// MPNowPlayingInfoCenter and MPRemoteCommandCenter behind NowPlayingCenter.
/// The command center is process-wide, so an app makes one and shares it.
@MainActor
public final class SystemNowPlayingCenter: NowPlayingCenter {
    public var onCommand: ((RemoteCommand) -> Void)?
    private let artwork: (UID) async -> Data?
    private var artworkTask: Task<Void, Never>?
    private var artworkItemId: UID?

    /// `artwork` fetches an item's poster bytes, as ArtworkStore.data does.
    public init(artwork: @escaping (UID) async -> Data?) {
        self.artwork = artwork
        let commands = MPRemoteCommandCenter.shared()
        let simple: [(MPRemoteCommand, RemoteCommand)] = [
            (commands.playCommand, .play), (commands.pauseCommand, .pause),
            (commands.togglePlayPauseCommand, .toggle), (commands.nextTrackCommand, .next),
            (commands.previousTrackCommand, .previous), (commands.stopCommand, .stop),
        ]
        for (command, value) in simple {
            command.addTarget { [weak self] _ in Self.handle(self, value) }
        }
        commands.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            return Self.handle(self, .seek(ms: Int64(event.positionTime * 1000)))
        }
        commands.changeShuffleModeCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangeShuffleModeCommandEvent else { return .commandFailed }
            return Self.handle(self, .shuffle(event.shuffleType != .off))
        }
        commands.changeRepeatModeCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangeRepeatModeCommandEvent else { return .commandFailed }
            let mode: RepeatMode =
                switch event.repeatType {
                case .one: .one
                case .all: .all
                default: .off
                }
            return Self.handle(self, .repeatMode(mode))
        }
    }

    /// The system calls command handlers on the main thread.
    private nonisolated static func handle(
        _ center: SystemNowPlayingCenter?, _ command: RemoteCommand
    ) -> MPRemoteCommandHandlerStatus {
        MainActor.assumeIsolated {
            guard let onCommand = center?.onCommand else { return .noActionableNowPlayingItem }
            onCommand(command)
            return .success
        }
    }

    public func show(_ info: NowPlayingInfo?) {
        let center = MPNowPlayingInfoCenter.default()
        guard let info else {
            center.nowPlayingInfo = nil
            artworkItemId = nil
            return
        }
        var values = Self.values(info)
        if info.artworkItemId != artworkItemId {
            loadArtwork(info.artworkItemId)
        } else if let art = center.nowPlayingInfo?[MPMediaItemPropertyArtwork] {
            values[MPMediaItemPropertyArtwork] = art
        }
        center.nowPlayingInfo = values
        #if os(macOS)
            center.playbackState = info.playing ? .playing : .paused
        #endif
        let commands = MPRemoteCommandCenter.shared()
        let transport: [MPRemoteCommand] = [
            commands.playCommand, commands.pauseCommand, commands.togglePlayPauseCommand, commands.nextTrackCommand,
            commands.previousTrackCommand, commands.changePlaybackPositionCommand, commands.changeShuffleModeCommand,
            commands.changeRepeatModeCommand,
        ]
        for command in transport { command.isEnabled = !info.stopOnly }
        commands.stopCommand.isEnabled = info.stopOnly
        commands.changeShuffleModeCommand.currentShuffleType = info.shuffled ? .items : .off
        commands.changeRepeatModeCommand.currentRepeatType =
            switch info.repeatMode {
            case .off: .off
            case .all: .all
            case .one: .one
            }
    }

    static func values(_ info: NowPlayingInfo) -> [String: Any] {
        var values: [String: Any] = [
            MPMediaItemPropertyTitle: info.title, MPMediaItemPropertyArtist: info.artist,
            MPMediaItemPropertyAlbumTitle: info.album,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: Double(info.elapsedMs) / 1000,
            MPNowPlayingInfoPropertyPlaybackRate: info.playing ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        if let duration = info.durationMs { values[MPMediaItemPropertyPlaybackDuration] = Double(duration) / 1000 }
        return values
    }

    /// Fetched once per album; a newer song's art replaces a slower older fetch.
    private func loadArtwork(_ id: UID) {
        artworkItemId = id
        artworkTask?.cancel()
        artworkTask = Task { [weak self, artwork] in
            guard let data = await artwork(id), !Task.isCancelled, let self, self.artworkItemId == id,
                let image = Self.image(data)
            else { return }
            MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtwork] = Self.artwork(image)
        }
    }

    /// The system draws artwork on a thread of its own, so the closure must
    /// not inherit the main actor.
    private nonisolated static func artwork(_ image: Image) -> MPMediaItemArtwork {
        nonisolated(unsafe) let image = image
        return MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }

    #if os(iOS) || os(tvOS)
        private typealias Image = UIImage
    #else
        private typealias Image = NSImage
    #endif
    private static func image(_ data: Data) -> Image? { Image(data: data) }
}
