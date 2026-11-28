import Foundation
import RabbitEarsAPI

public typealias DownloadQuality = Components.Schemas.DownloadQuality
public typealias DownloadTitle = Components.Schemas.DownloadTitle
public typealias ServerDownload = Components.Schemas.Download

/// What a More menu's Download asks for. A movie, episode, song or video
/// stands for itself; anything else is standing, covering what it holds
/// as that changes. Identity is the scope and id alone.
public struct DownloadTarget: Hashable, Codable, Sendable {
    public enum Scope: String, Codable, Sendable { case item, collection, playlist }

    public let scope: Scope
    public let id: UID
    public let editionId: UID?
    public let standing: Bool
    /// Music offers Original or AAC 256; video the picture sizes.
    public let music: Bool
    /// What the Downloads list calls it.
    public let name: String

    public init(scope: Scope, id: UID, name: String, standing: Bool, music: Bool = false, editionId: UID? = nil) {
        self.scope = scope
        self.id = id
        self.name = name
        self.standing = standing
        self.music = music
        self.editionId = editionId
    }

    public var key: String { "\(scope.rawValue)/\(id)" }

    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.key == rhs.key }
    public func hash(into hasher: inout Hasher) { hasher.combine(key) }

    public static func item(_ item: Item, editionId: UID? = nil) -> Self {
        let single = item.kind == .movie || item.kind == .episode
        return Self(
            scope: .item, id: item.id, name: Catalog.title(item), standing: !single, editionId: single ? editionId : nil
        )
    }

    public static func song(_ song: MusicSong) -> Self {
        Self(scope: .item, id: song.id, name: song.title, standing: false, music: true)
    }

    public static func album(_ album: MusicAlbum) -> Self {
        Self(scope: .item, id: album.id, name: album.title, standing: true, music: true)
    }

    public static func artist(_ artist: MusicArtist) -> Self {
        Self(scope: .item, id: artist.id, name: artist.name, standing: true, music: true)
    }

    public static func video(_ video: YouTubeVideo) -> Self {
        Self(scope: .item, id: video.id, name: video.title, standing: false)
    }

    public static func channel(_ channel: YouTubeChannel) -> Self {
        Self(scope: .item, id: channel.id, name: channel.title, standing: true)
    }

    public static func collection(_ collection: MovieCollection) -> Self {
        Self(scope: .collection, id: collection.id, name: collection.name, standing: true)
    }

    public static func playlist(_ playlist: Playlist) -> Self {
        Self(scope: .playlist, id: playlist.id, name: playlist.name, standing: true, music: playlist.kind == .music)
    }

    var input: Components.Schemas.DownloadTarget {
        switch scope {
        case .item: .init(itemId: id, editionId: editionId)
        case .collection: .init(collectionId: id)
        case .playlist: .init(playlistId: id)
        }
    }
}

/// Where one stored title is on its way to the device.
public enum DownloadState: Codable, Equatable, Sendable {
    case pending
    case waitingForWiFi
    case waitingForLowData
    case waitingForSpace
    /// Its transfer waits on the server, which sends nothing until the file
    /// is ready; the share is never shown, as nothing updates it meanwhile.
    case preparing(Double)
    case downloading(Double)
    case onDevice
    case failed(String)

    /// What the Downloads list says of it.
    public var label: String {
        switch self {
        case .pending: "Waiting"
        case .waitingForWiFi: "Waiting for Wi-Fi"
        case .waitingForLowData: "Waiting: Low Data Mode is on"
        case .waitingForSpace: "Waiting for space"
        case .preparing: "Preparing"
        case .downloading(let share): "Downloading \(Int(share * 100))%"
        case .onDevice: "On this device"
        case .failed(let reason): "Failed: \(reason)"
        }
    }

    /// What the network holds a transfer for: Low Data Mode always, a
    /// metered path while Wi-Fi only is on; nil lets it go.
    public static func waiting(wifiOnly: Bool, expensive: Bool, constrained: Bool) -> Self? {
        if constrained { return .waitingForLowData }
        return wifiOnly && expensive ? .waitingForWiFi : nil
    }

    /// Counted against the allowance: on the device or on its way.
    var holdsSpace: Bool {
        switch self {
        case .preparing, .downloading, .onDevice: true
        default: false
        }
    }
}

/// A text subtitle kept beside a stored title, as WebVTT.
public struct StoredSubtitle: Codable, Equatable, Sendable {
    public let trackId: UID
    public let language: String?
    public let title: String?
    public let isForced: Bool
    public let file: String
}

/// One title's single stored copy on this device, whichever requests and
/// profiles cover it.
public struct StoredTitle: Codable, Equatable, Sendable, Identifiable {
    public let itemId: UID
    public let kind: DownloadTitle.KindPayload
    public let libraryId: UID
    public var editionId: UID?
    /// The server's file this copy is of, once fetched.
    var mediaFileId: UID?
    public var quality: DownloadQuality
    public var sizeBytes: Int64
    public var runtimeMs: Int64?
    public var state: DownloadState = .pending
    /// The file's name in the media folder, once fetched.
    public var file: String?
    public var subtitles: [StoredSubtitle] = []
    var resumeData: Data?
    /// The server's claim on the file, kept until released so no pass, retry or relaunch claims twice.
    var claim: DownloadClaim?
    /// The artwork files it shows with, its parents' included.
    var art: [String]?
    /// What holds it in the replica: season and show, album and artists, or channel.
    var above: [UID]?
    public var id: UID { itemId }

    init(_ title: DownloadTitle, quality: DownloadQuality) {
        itemId = title.itemId
        kind = title.kind
        libraryId = title.libraryId
        editionId = title.editionId
        self.quality = title.quality ?? quality
        sizeBytes = title.sizeBytes ?? 0
        runtimeMs = title.runtimeMs
    }
}

/// A download the server made for this device: what fetches its file and
/// what releases it.
struct DownloadClaim: Codable, Equatable, Sendable {
    let id: UID
    let profileId: UID
    let container: String

    /// Held by the server until the file is ready, then served.
    var file: String { "/api/v2/downloads/\(id)/file?wait=1" }
}

/// One profile's standing or single request, with what it covers now in play order.
public struct DownloadRequest: Codable, Equatable, Sendable, Identifiable {
    public let profileId: UID
    public let target: DownloadTarget
    public var quality: DownloadQuality
    public var titles: [UID]
    public let createdAt: Date
    /// The artwork files a collection or playlist shows with.
    var art: [String]?
    public var id: String { "\(profileId) \(target.key)" }
}

/// A profile's Downloads preferences on this device.
public struct DownloadSettings: Codable, Equatable, Sendable {
    public var preferLocal = true
    /// What Download picks first; music takes Original or AAC 256 from it.
    public var quality: DownloadQuality = .original
    /// By library: whether a watched title stays; absent is the kind's default.
    public var keep: [UID: Bool] = [:]
    /// Off after Don't ask again on a big request.
    public var confirmBig = true

    public init() {}

    /// Movies keep and TV and YouTube remove once watched, unless set; music always keeps.
    public func keeps(library: UID, kind: DownloadTitle.KindPayload) -> Bool {
        if kind == .song { return true }
        return keep[library] ?? (kind == .movie)
    }

    public func keeps(_ library: DownloadLibrary) -> Bool {
        library.kind == .music || (keep[library.id] ?? (library.kind == .movies))
    }
}

/// A library of the server, as Downloads' keep-watched settings name it.
public struct DownloadLibrary: Equatable, Sendable {
    public let id: UID
    public let name: String
    public let kind: Components.Schemas.LibraryKind
}

/// What a big request is, for "This is a lot" before it is kept.
public struct DownloadPlan: Sendable {
    public let profileId: UID
    public let target: DownloadTarget
    public let quality: DownloadQuality
    public let titles: [DownloadTitle]
    public var count: Int { titles.count }
    public var sizeBytes: Int64 { titles.reduce(0) { $0 + ($1.sizeBytes ?? 0) } }
}
