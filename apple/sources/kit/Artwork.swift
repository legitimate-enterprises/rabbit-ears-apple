import Foundation
import GRDB
import ImageIO
import OpenAPIRuntime
import RabbitEarsAPI

/// Artwork, headshots and custom images from the server, held in memory for the signed-in session;
/// beneath it, URLCache keeps images on disk under the server's Cache-Control. Art is fetched at the
/// address the replica names for it as the active profile is shown it, and an address names one image
/// for good, so it keys every cache: art is fetched again only once its address changes. An image the
/// server does not have stays missing; one that failed to arrive is asked for again, and meanwhile is
/// the copy `kept` holds from its last arrival.
@MainActor
public final class ArtworkStore {
    public enum Kind: String, Sendable { case poster, backdrop }

    /// The address of a key's art as the active profile is shown it; nil when it has none.
    public typealias Addresser = @MainActor (ArtKey) async -> String?

    let client: Client
    private let images = NSCache<NSString, NSData>()
    /// Decoded bitmaps by address and size, costed in bytes; views drop theirs
    /// when they scroll away, so this bounds what a long grid holds.
    let bitmaps = NSCache<NSString, CGImage>()
    private var loading: [String: Task<Fetched, Never>] = [:]
    private var missing: Set<String> = []
    private let kept: URLCache?
    private let address: Addresser
    /// Each key's address as last read for the active profile, which names the art in memory a view
    /// shows at once; every ask reads it again.
    private var addresses: [ArtKey: String] = [:]

    private enum Fetched {
        case found(Data)
        case missing, failed
    }

    public init(client: Client, kept: URLCache? = nil, address: @escaping Addresser = { _ in nil }) {
        self.client = client
        self.kept = kept
        self.address = address
        images.totalCostLimit = 64 << 20
        bitmaps.totalCostLimit = 96 << 20
    }

    /// The artwork decoded no larger than `maxPixel` on its long side; nil
    /// when there is none or it cannot be decoded.
    public func image(_ id: UID, _ kind: Kind, maxPixel: Int) async -> CGImage? {
        await image(ArtKey(id: id, kind: kind), maxPixel)
    }

    public func image(collection id: UID, _ kind: Kind, maxPixel: Int) async -> CGImage? {
        await image(ArtKey(id: id, kind: kind, collection: true), maxPixel)
    }

    public func headshotImage(_ personId: UID, maxPixel: Int) async -> CGImage? {
        await bitmap("person/\(personId)", maxPixel) { await self.headshot(personId) }
    }

    /// The artwork decoded at this size if it is in memory now, so a view that has it needs no
    /// placeholder or fade.
    public func resident(_ id: UID, _ kind: Kind, maxPixel: Int) -> CGImage? {
        resident(ArtKey(id: id, kind: kind), maxPixel)
    }

    public func resident(collection id: UID, _ kind: Kind, maxPixel: Int) -> CGImage? {
        resident(ArtKey(id: id, kind: kind, collection: true), maxPixel)
    }

    /// The image bytes, or nil when the item has none or the server is unreachable.
    public func data(_ id: UID, _ kind: Kind) async -> Data? {
        guard let url = await located(ArtKey(id: id, kind: kind)) else { return nil }
        return await data(imageUrl: url)
    }

    /// A collection's own image, else its first movie's; nil when none has one.
    public func data(collection id: UID, _ kind: Kind) async -> Data? {
        guard let url = await located(ArtKey(id: id, kind: kind, collection: true)) else { return nil }
        return await data(imageUrl: url)
    }

    /// The image an address the data carries names, decoded no larger than `maxPixel`; nil when it
    /// cannot be had.
    public func image(url: String, maxPixel: Int) async -> CGImage? {
        await bitmap(url, maxPixel) { await self.data(imageUrl: url) }
    }

    /// The bytes at an artwork address or a custom image's imageUrl; nil for any other.
    public func data(imageUrl url: String) async -> Data? {
        let client = client
        if let path = Self.artworkPath(url) {
            return await cached(url) { try await client.getArtwork(path: path).ok.body.image_Ast_ }
        }
        guard let (target, version) = CustomImage.route(url) else { return nil }
        return await cached(url) {
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

    /// The getArtwork path an address names, as `/api/v2/artwork/w500/a.jpg`; nil for any other.
    static func artworkPath(_ url: String) -> Operations.GetArtwork.Input.Path? {
        let path = (URLComponents(string: url)?.path ?? "").split(separator: "/").map(String.init)
        guard path.count == 5, path[0...2] == ["api", "v2", "artwork"],
            let store = Components.Schemas.ArtworkStore(rawValue: path[3])
        else { return nil }
        return .init(store: store, name: path[4])
    }

    public func headshot(_ personId: UID) async -> Data? {
        let client = client
        return await cached("person/\(personId)") {
            try await client.getPersonArtwork(path: .init(personId: personId)).ok.body.image_Ast_
        }
    }

    public func avatarImage(_ account: Account, maxPixel: Int) async -> CGImage? {
        await bitmap("avatar/\(account.id)", maxPixel) { await self.avatar(account) }
    }

    /// The server's cached picture of a profile; nil, unasked, when the account carries no avatarUrl.
    public func avatar(_ account: Account) async -> Data? {
        guard account.avatarUrl != nil else { return nil }
        let client = client
        return await cached("avatar/\(account.id)") {
            try await client.getProfileAvatar(path: .init(profileId: account.id)).ok.body.image_Ast_
        }
    }

    func bitmap(_ key: String, _ maxPixel: Int, _ bytes: () async -> Data?) async -> CGImage? {
        let key = "\(key)@\(maxPixel)" as NSString
        if let hit = bitmaps.object(forKey: key) { return hit }
        guard maxPixel > 0, let data = await bytes(), let image = await Self.downsample(data, maxPixel: maxPixel)
        else { return nil }
        bitmaps.setObject(image, forKey: key, cost: image.bytesPerRow * image.height)
        return image
    }

    /// Decodes on a background thread, never upscaling, so the main actor
    /// never waits on a JPEG.
    @concurrent
    nonisolated static func downsample(_ data: Data, maxPixel: Int) async -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true, kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// What one profile is shown another may not be, so no address read for the last one stands.
    func profileChanged() {
        addresses = [:]
    }

    private func image(_ key: ArtKey, _ maxPixel: Int) async -> CGImage? {
        guard let url = await located(key) else { return nil }
        return await image(url: url, maxPixel: maxPixel)
    }

    private func resident(_ key: ArtKey, _ maxPixel: Int) -> CGImage? {
        addresses[key].flatMap { bitmaps.object(forKey: "\($0)@\(maxPixel)" as NSString) }
    }

    private func located(_ key: ArtKey) async -> String? {
        let url = await address(key)
        addresses[key] = url
        return url
    }

    func cached(_ key: String, _ fetch: @escaping @Sendable () async throws -> HTTPBody) async -> Data? {
        if let hit = images.object(forKey: key as NSString) { return hit as Data }
        if missing.contains(key) { return nil }
        let task =
            loading[key]
            ?? Task<Fetched, Never> {
                do {
                    return .found(try await Data(collecting: try await fetch(), upTo: 16 << 20))
                } catch {
                    return APIError.from(error)?.status == 404 ? .missing : .failed
                }
            }
        loading[key] = task
        let outcome = await task.value
        loading[key] = nil
        switch outcome {
        case .found(let data):
            images.setObject(data as NSData, forKey: key as NSString, cost: data.count)
            let request = Self.keptRequest(key)
            let response = URLResponse(
                url: request.url!, mimeType: nil, expectedContentLength: data.count, textEncodingName: nil)
            kept?.storeCachedResponse(CachedURLResponse(response: response, data: data), for: request)
            return data
        case .missing:
            missing.insert(key)
            return nil
        case .failed:
            return kept?.cachedResponse(for: Self.keptRequest(key))?.data
        }
    }

    /// An address no server answers, so a kept image never stands in for a response.
    private static func keptRequest(_ key: String) -> URLRequest {
        URLRequest(url: URL(string: "https://artwork.invalid")!.appending(path: key))
    }
}

/// What art is shown for: an item's or a collection's poster or backdrop.
public struct ArtKey: Hashable, Sendable {
    let id: UID
    let kind: ArtworkStore.Kind
    let collection: Bool

    init(id: UID, kind: ArtworkStore.Kind, collection: Bool = false) {
        self.id = id
        self.kind = kind
        self.collection = collection
    }

    /// The address the replica names for this art as `profile` is shown it; nil when there is none.
    func address(for profile: UID, _ db: Database) throws -> String? {
        let column = kind == .poster ? "poster_url" : "backdrop_url"
        let sql =
            collection
            ? "SELECT \(column) FROM profile_collection_art WHERE account_id = ? AND collection_id = ?"
            : "SELECT \(column) FROM profile_art WHERE account_id = ? AND item_id = ?"
        return try String.fetchOne(db, sql: sql, arguments: [profile, id])
    }
}
