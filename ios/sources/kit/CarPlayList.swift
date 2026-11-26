import Foundation
import RabbitEarsAPI

public typealias MusicLetterGroup = Components.Schemas.MusicLetterGroup

/// A title and the line under it, for a CarPlay list with nothing to show.
public struct CarPlayMessage: Equatable, Sendable {
    public let title: String
    public let detail: String?

    public init(_ title: String, _ detail: String? = nil) {
        self.title = title
        self.detail = detail
    }

    static let noMusic = CarPlayMessage("No music yet", "Albums appear here after your server\u{2019}s next scan.")
    static let noPlaylists = CarPlayMessage("No playlists")
}

/// Whether CarPlay can browse music, and if not, why. CarPlay follows the
/// profile the server has active on this phone and never switches it; a
/// kid's is the music the server allows them.
public enum CarPlayGate: Equatable, Sendable {
    case loading, notSignedIn, choosingProfile, unreachable, offline
    case music(Int64)

    /// `reachable` is false after a music read found the server gone. The
    /// phone choosing its household or at Who's watching has no profile for
    /// CarPlay to follow. With no connection, the profile's downloaded music
    /// still plays.
    public init(
        phase: AppModel.Phase, profile: Account?, online: Bool, reachable: Bool, downloadedMusic: Bool = false
    ) {
        if phase == .signedOut {
            self = .notSignedIn
        } else if phase == .choosingHousehold || phase == .choosingProfile {
            self = .choosingProfile
        } else if !online && !downloadedMusic {
            self = .offline
        } else if phase == .unreachable || !reachable {
            self = .unreachable
        } else if phase == .starting || profile == nil {
            self = .loading
        } else {
            self = .music(profile?.id ?? 0)
        }
    }

    /// The copy of the states with no music; nil while loading and for music.
    public var message: CarPlayMessage? {
        let retrying = "Rabbit Ears keeps trying and reconnects on its own."
        return switch self {
        case .loading, .music: nil
        case .notSignedIn: CarPlayMessage("Not signed in", "Music appears here once Rabbit Ears is signed in.")
        case .choosingProfile:
            CarPlayMessage(
                "Choose who\u{2019}s watching on your iPhone", "Music appears here once a profile is picked.")
        case .unreachable: CarPlayMessage("Can\u{2019}t reach your server", retrying)
        case .offline: CarPlayMessage("No connection", retrying)
        }
    }
}

extension DownloadStore {
    /// Whether any of the profile's own downloads is a song on this device.
    public func hasMusic(for profile: Int64) -> Bool {
        requests(for: profile).flatMap(\.titles).contains {
            titles[$0]?.kind == .song && titles[$0]?.state == .onDevice
        }
    }
}

/// What each tab last showed. A tab that finds the server gone says so in
/// itself; the whole car says so only once no tab has anything to show.
public struct CarPlayTabs<Tab: Hashable> {
    private enum Shown { case waiting, rows, nothing, unreachable }
    private var shown: [Tab: Shown]

    public init(_ tabs: [Tab]) {
        shown = Dictionary(uniqueKeysWithValues: tabs.map { ($0, .waiting) })
    }

    /// A list that is not a tab changes nothing.
    public mutating func answered(_ tab: Tab, rows: Bool) {
        if shown[tab] != nil { shown[tab] = rows ? .rows : .nothing }
    }

    public mutating func unreachable(_ tab: Tab) {
        if shown[tab] != nil { shown[tab] = .unreachable }
    }

    /// Every tab has answered, none with rows, and one found the server gone.
    public var nothingAnywhere: Bool {
        let all = Set(shown.values)
        return all.contains(.unreachable) && all.isDisjoint(with: [.waiting, .rows])
    }
}

/// What a CarPlay list may hold in this car.
public struct CarPlayLimits: Equatable, Sendable {
    public let maxItems: Int
    public let maxSections: Int
    /// The car limits lists, as while driving in some cars.
    public let limited: Bool

    public init(maxItems: Int, maxSections: Int, limited: Bool) {
        self.maxItems = maxItems
        self.maxSections = maxSections
        self.limited = limited
    }
}

public enum CarPlayDestination: Equatable, Sendable {
    case album(Int64)
    case artist(Int64)
    case playlist(Int64)
    case letter(MusicLetterGroup, String)
}

/// Something Play, Shuffle or a Recent row plays from the top.
public enum CarPlayPlayable: Equatable, Sendable {
    case album(Int64)
    case playlist(Int64)
    case artist(Int64, name: String)
}

public enum CarPlayAction: Equatable, Sendable {
    case open(CarPlayDestination)
    case play(CarPlayPlayable)
    /// Plays the list's queue from this song.
    case playTrack(Int)
    case jump(AudioQueue.Entry.ID)
    /// Tunes in to a music station through the shared player.
    case tune(Station)
}

public struct CarPlayRow: Equatable, Sendable {
    public enum Art: Equatable, Sendable {
        case square(Int64)
        case round(Int64)
        /// A playlist's or station's own image, by its imageUrl.
        case custom(String)
    }

    /// What the row stands for, so it shows the playing indicator.
    public enum Marker: Equatable, Sendable {
        case album(Int64)
        case song(Int64)

        public func matches(_ song: MusicSong?) -> Bool {
            guard let song else { return false }
            return switch self {
            case .album(let id): song.albumId == id
            case .song(let id): song.id == id
            }
        }
    }

    public let text: String
    public let detail: String?
    public let art: Art?
    public let action: CarPlayAction
    public let marker: Marker?

    /// Shows a chevron; every other row plays.
    public var opens: Bool {
        if case .open = action { return true }
        return false
    }
}

public struct CarPlaySection: Equatable, Sendable {
    public let header: String?
    public let index: String?
    public let rows: [CarPlayRow]
}

/// The details header of Artist, Album and a playlist, with Play and Shuffle.
public struct CarPlayHeader: Equatable, Sendable {
    public let art: CarPlayRow.Art?
    public let title: String
    public let subtitle: String
    public let play: CarPlayPlayable
}

/// Songs to hand the music player, and what they play from.
public struct CarPlayQueue: Equatable, Sendable {
    public let songs: [MusicSong]
    public let source: String
    public let playlistId: Int64?
}

public struct CarPlayList: Equatable, Sendable {
    public var title: String?
    public var header: CarPlayHeader?
    public var sections: [CarPlaySection]
    /// Shown when there are no rows.
    public var empty: CarPlayMessage?
    /// What `playTrack` plays from.
    public var queue: CarPlayQueue?

    public init(
        title: String? = nil, header: CarPlayHeader? = nil, sections: [CarPlaySection], empty: CarPlayMessage? = nil,
        queue: CarPlayQueue? = nil
    ) {
        self.title = title
        self.header = header
        self.sections = sections
        self.empty = empty
        self.queue = queue
    }

    /// The rows the car holds, in order, and only the sections with room
    /// left; the queue keeps every song, so Play plays them all.
    func capped(_ limits: CarPlayLimits) -> CarPlayList {
        var room = limits.maxItems
        var list = self
        list.sections = sections.prefix(limits.maxSections).compactMap { section in
            let rows = Array(section.rows.prefix(max(0, room)))
            room -= rows.count
            return rows.isEmpty ? nil : CarPlaySection(header: section.header, index: section.index, rows: rows)
        }
        return list
    }
}

/// A button on CarPlay's Now Playing beside the system's transport.
public enum CarPlayNowPlayingButton: Equatable, Sendable { case shuffle, repeatMode }
