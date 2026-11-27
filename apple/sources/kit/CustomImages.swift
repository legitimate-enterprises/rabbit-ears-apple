import Foundation
import ImageIO
import Observation
import OpenAPIRuntime
import RabbitEarsAPI
import UniformTypeIdentifiers

/// What a custom image is set on: a playlist under its owner's profile, or a station.
public enum ImageTarget: Hashable, Sendable {
    case playlist(profileId: UID, playlistId: UID)
    case station(UID)
}

/// How the owner gives a custom image.
public enum ImageSource: Sendable {
    /// A file or photo from the device, in any format the system reads.
    case file(Data)
    /// One of the playlist's titles' artwork.
    case artwork(itemId: UID, kind: ArtworkStore.Kind)
    /// A link the server fetches once.
    case link(String)
}

/// One choice of "Pick a title's artwork".
public struct ArtChoice: Hashable, Sendable, Identifiable {
    public let itemId: UID
    public let kind: ArtworkStore.Kind
    public let label: String
    public var id: String { "\(itemId)/\(kind.rawValue)" }
}

/// An owner's Set image request: where it goes, and the playlist whose titles it may pick from.
public struct ImageRequest: Identifiable, Sendable {
    public let target: ImageTarget
    public let playlistId: UID
    public let hasImage: Bool
    public var id: ImageTarget { target }

    public init(playlist: Playlist, profileId: UID) {
        target = .playlist(profileId: profileId, playlistId: playlist.id)
        playlistId = playlist.id
        hasImage = playlist.imageUrl != nil
    }

    public init(station: Station) {
        target = .station(station.id)
        playlistId = station.playlistId
        hasImage = station.imageUrl != nil
    }
}

public enum CustomImage {
    /// The route an imageUrl names and its version, the cover's id; nil for any other address.
    public static func route(_ url: String) -> (target: ImageTarget, version: String)? {
        guard let parts = URLComponents(string: url),
            let version = parts.queryItems?.first(where: { $0.name == "v" })?.value, !version.isEmpty
        else { return nil }
        let path = parts.path.split(separator: "/").map(String.init)
        if path.count == 7, path[0...2] == ["api", "v2", "profiles"], path[4] == "playlists", path[6] == "image",
            let profile = UID(path[3]), let playlist = UID(path[5])
        {
            return (.playlist(profileId: profile, playlistId: playlist), version)
        }
        if path.count == 5, path[0...2] == ["api", "v2", "stations"], path[4] == "image", let station = UID(path[3]) {
            return (.station(station), version)
        }
        return nil
    }

    /// The artwork the entries offer, each title once: a poster, and a backdrop for movies and
    /// TV; music has only covers, and a collection offers none.
    public static func choices(_ entries: [PlaylistEntry]) -> [ArtChoice] {
        var seen = Set<UID>()
        return entries.flatMap { entry -> [ArtChoice] in
            guard let id = entry.itemId, seen.insert(id).inserted else { return [] }
            let name = PlaylistText.title(entry)
            let kinds: [ArtworkStore.Kind] = entry.item == nil ? [.poster] : [.poster, .backdrop]
            return kinds.map { ArtChoice(itemId: id, kind: $0, label: "\(name), \($0.rawValue)") }
        }
    }

    /// A file the system reads, HEIC included, as an upright JPEG no larger than maxPixel on
    /// its long side, which the server takes; nil when it is not an image.
    public static func uploadable(_ data: Data, maxPixel: Int = 3200) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let jpeg = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(jpeg, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        return CGImageDestinationFinalize(jpeg) ? out as Data : nil
    }
}

/// Sets and removes a playlist's or station's custom image; the server allows its owner only.
@MainActor
@Observable
public final class CustomImageModel {
    public private(set) var error: String?
    public private(set) var busy = false
    let client: Client

    public init(client: Client) { self.client = client }

    /// True once the server keeps it.
    public func set(_ source: ImageSource, on target: ImageTarget) async -> Bool {
        let body: Operations.ReplacePlaylistImage.Input.Body
        switch source {
        case .file(let data):
            guard let jpeg = CustomImage.uploadable(data) else {
                error = "That file is not an image."
                return false
            }
            body = .binary(HTTPBody(jpeg))
        case .artwork(let itemId, let kind):
            body = .json(.init(itemId: itemId, kind: kind == .poster ? .poster : .backdrop))
        case .link(let url):
            let url = url.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !url.isEmpty else { return false }
            body = .json(.init(url: url))
        }
        return await write {
            switch target {
            case .playlist(let profileId, let playlistId):
                _ = try await client.replacePlaylistImage(
                    path: .init(profileId: profileId, playlistId: playlistId), body: body
                ).ok
            case .station(let id):
                _ = try await client.replaceStationImage(path: .init(stationId: id), body: Self.station(body)).ok
            }
        }
    }

    /// True once the image is gone, back to what shows without one.
    public func remove(from target: ImageTarget) async -> Bool {
        await write {
            switch target {
            case .playlist(let profileId, let playlistId):
                _ = try await client.deletePlaylistImage(path: .init(profileId: profileId, playlistId: playlistId))
                    .noContent
            case .station(let id):
                _ = try await client.deleteStationImage(path: .init(stationId: id)).noContent
            }
        }
    }

    private typealias StationBody = Operations.ReplaceStationImage.Input.Body

    private static func station(_ body: Operations.ReplacePlaylistImage.Input.Body) -> StationBody {
        switch body {
        case .binary(let data): .binary(data)
        case .json(let input): .json(input)
        }
    }

    private func write(_ body: () async throws -> Void) async -> Bool {
        busy = true
        defer { busy = false }
        do {
            try await body()
            error = nil
            return true
        } catch {
            self.error =
                APIError.from(error)?.fieldMessages.values.first
                ?? AppError.from(error, unauthorized: .signedOut).localizedDescription
            return false
        }
    }
}

extension ArtworkStore {
    /// The custom image an imageUrl names, decoded no larger than `maxPixel`; nil when it
    /// cannot be had. The address changes with the cover, so it keys the caches; a picked
    /// title's art changing under it moves the generation, which empties them.
    public func image(url: String, maxPixel: Int) async -> CGImage? {
        await bitmap("image:\(url)", maxPixel) { await self.data(imageUrl: url) }
    }

    public func data(imageUrl url: String) async -> Data? {
        guard let (target, version) = CustomImage.route(url) else { return nil }
        let client = client
        return await cached("image:\(url)") {
            switch target {
            case .playlist(let profileId, let playlistId):
                try await client.getPlaylistImage(
                    path: .init(profileId: profileId, playlistId: playlistId), query: .init(v: version)
                ).ok.body.image_Ast_
            case .station(let id):
                try await client.getStationImage(path: .init(stationId: id), query: .init(v: version)).ok.body
                    .image_Ast_
            }
        }
    }
}
