import Foundation
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
