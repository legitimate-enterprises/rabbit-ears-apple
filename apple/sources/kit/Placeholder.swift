import Foundation
import HTTPTypes
import OpenAPIRuntime
import RabbitEarsAPI

/// What a tile shows over its flat color while its image loads, and for good when it has none.
public enum PlaceholderKind: String, CaseIterable, Sendable {
    case movie, show, album, artist, song, channel, video, playlist, station, collection, person

    /// A season and an episode show their show's.
    public init(itemKind: ItemKind) {
        switch itemKind {
        case .movie: self = .movie
        case .show, .season, .episode: self = .show
        }
    }

    /// The SF Symbol drawn for it.
    public var symbol: String {
        switch self {
        case .movie: "film"
        case .show: "tv"
        case .album: "opticaldisc"
        case .artist: "music.mic"
        case .song: "music.note"
        case .channel: "play.tv"
        case .video: "play.rectangle"
        case .playlist: "list.bullet.rectangle"
        case .station: "antenna.radiowaves.left.and.right"
        case .collection: "rectangle.stack"
        case .person: "person.fill"
        }
    }
}

/// The artwork generation the server names on its answers. Images are asked
/// for under it, so a cache keeps one until some image changes and the server
/// says so on whatever is asked next.
public final class ArtworkGeneration: ClientMiddleware, @unchecked Sendable {
    private let lock = NSLock()
    private var named: Int64?

    public init() {}

    public var value: Int64? { lock.withLock { named } }

    private static let header = HTTPField.Name("Artwork-Generation")!
    /// An image answered from URLCache carries the generation it was stored under.
    private static let images: Set<String> = [
        "getItemArtwork", "getCollectionArtwork", "getPersonArtwork", "getProfileAvatar",
        "getPlaylistImage", "getStationImage",
    ]

    public func intercept(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String,
        next: (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        let answer = try await next(request, body, baseURL)
        if !Self.images.contains(operationID), let text = answer.0.headerFields[Self.header],
            let generation = Int64(text),
            generation > 0
        {
            lock.withLock { named = generation }
        }
        return answer
    }
}
