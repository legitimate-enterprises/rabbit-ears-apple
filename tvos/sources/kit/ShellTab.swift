import RabbitEarsKit

/// A section in the Apple TV top bar, in bar order.
public enum ShellTab: CaseIterable, Hashable, Sendable {
    case home, tv, movies, music, youTube, search

    /// The libraries a tab lists; nil for a tab that always shows.
    public var library: LibrarySection? {
        switch self {
        case .tv: .tv
        case .movies: .movies
        case .music: .music
        case .youTube: .youtube
        case .home, .search: nil
        }
    }

    public var title: String {
        switch self {
        case .home: "Home"
        case .tv: "TV"
        case .movies: "Movies"
        case .music: "Music"
        case .youTube: "YouTube"
        case .search: "Search"
        }
    }
}
