import Foundation
import ImageIO
import OpenAPIRuntime
import RabbitEarsAPI

/// Item artwork and headshots from the server, held in memory for the signed-in session; beneath it,
/// URLCache keeps images on disk under the server's Cache-Control. An image the server does not have
/// stays missing until the artwork generation moves; one that failed to arrive is asked for again.
@MainActor
public final class ArtworkStore {
    public enum Kind: String, Sendable { case poster, backdrop }

    let client: Client
    private let images = NSCache<NSString, NSData>()
    /// Decoded bitmaps by key and size, costed in bytes; views drop theirs
    /// when they scroll away, so this bounds what a long grid holds.
    let bitmaps = NSCache<NSString, CGImage>()
    private var loading: [String: Task<Fetched, Never>] = [:]
    private var missing: Set<String> = []
    private let generation: ArtworkGeneration?
    private var seen: Int64?

    private enum Fetched {
        case found(Data)
        case missing, failed
    }

    public init(client: Client, generation: ArtworkGeneration? = nil) {
        self.client = client
        self.generation = generation
        images.totalCostLimit = 64 << 20
        bitmaps.totalCostLimit = 96 << 20
    }

    /// The artwork decoded no larger than `maxPixel` on its long side; nil
    /// when there is none or it cannot be decoded.
    public func image(_ id: Int64, _ kind: Kind, maxPixel: Int) async -> CGImage? {
        await bitmap("\(id)/\(kind.rawValue)", maxPixel) { await self.data(id, kind) }
    }

    public func image(collection id: Int64, _ kind: Kind, maxPixel: Int) async -> CGImage? {
        await bitmap("collection/\(id)/\(kind.rawValue)", maxPixel) { await self.data(collection: id, kind) }
    }

    public func headshotImage(_ personId: Int64, maxPixel: Int) async -> CGImage? {
        await bitmap("person/\(personId)", maxPixel) { await self.headshot(personId) }
    }

    /// The artwork decoded at this size if it is in memory now, so a view that has it needs no
    /// placeholder or fade.
    public func resident(_ id: Int64, _ kind: Kind, maxPixel: Int) -> CGImage? {
        _ = currentGeneration()
        return bitmaps.object(forKey: "\(id)/\(kind.rawValue)@\(maxPixel)" as NSString)
    }

    public func resident(collection id: Int64, _ kind: Kind, maxPixel: Int) -> CGImage? {
        _ = currentGeneration()
        return bitmaps.object(forKey: "collection/\(id)/\(kind.rawValue)@\(maxPixel)" as NSString)
    }

    /// The image bytes, or nil when the item has none or the server is unreachable.
    public func data(_ id: Int64, _ kind: Kind) async -> Data? {
        let client = client
        let query = Operations.GetItemArtwork.Input.Query(v: currentGeneration())
        return await cached("\(id)/\(kind.rawValue)") {
            let path = Operations.GetItemArtwork.Input.Path(itemId: id, kind: kind == .poster ? .poster : .backdrop)
            return try await client.getItemArtwork(path: path, query: query).ok.body.image_Ast_
        }
    }

    /// A collection's own image, else its first movie's; nil when none has one.
    public func data(collection id: Int64, _ kind: Kind) async -> Data? {
        let client = client
        let query = Operations.GetCollectionArtwork.Input.Query(v: currentGeneration())
        return await cached("collection/\(id)/\(kind.rawValue)") {
            let path = Operations.GetCollectionArtwork.Input.Path(
                collectionId: id, kind: kind == .poster ? .poster : .backdrop)
            return try await client.getCollectionArtwork(path: path, query: query).ok.body.image_Ast_
        }
    }

    public func headshot(_ personId: Int64) async -> Data? {
        let client = client
        let query = Operations.GetPersonArtwork.Input.Query(v: currentGeneration())
        return await cached("person/\(personId)") {
            try await client.getPersonArtwork(path: .init(personId: personId), query: query).ok.body.image_Ast_
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
        _ = currentGeneration()
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

    /// What one profile may not see another may, so art missing for the last one is asked for again.
    func profileChanged() {
        missing = []
    }

    /// The generation the server last named. Images are asked for under it, which lets the server have
    /// URLCache keep one until some image changes; when it has moved, what is held, and what was
    /// missing, is asked for again. The first one named only starts the asking under it.
    private func currentGeneration() -> Int64? {
        let named = generation?.value
        if named != seen {
            if seen != nil {
                images.removeAllObjects()
                bitmaps.removeAllObjects()
                missing = []
            }
            seen = named
        }
        return named
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
            return data
        case .missing:
            missing.insert(key)
            return nil
        case .failed:
            return nil
        }
    }
}
