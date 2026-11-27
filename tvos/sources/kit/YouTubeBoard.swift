import Foundation
import Observation
import RabbitEarsAPI

/// What the YouTube screen lists for the tab, sort and channel in view.
@MainActor
@Observable
public final class YouTubeBoard {
    public private(set) var videos: Pager<YouTubeVideo>?
    public private(set) var channels: [YouTubeChannel] = []
    private let youTube: YouTubeModel

    public init(youTube: YouTubeModel) { self.youTube = youTube }

    /// The count and the Channel menu need every channel, whichever tab is chosen.
    public func loadChannels() async {
        channels = (try? await youTube.channels()) ?? []
    }

    public var caption: String { channels.count == 1 ? "1 channel" : "\(channels.count.formatted()) channels" }

    /// Videos and Unwatched page in as the grid scrolls (`loadMore`), since
    /// a library of channels holds thousands.
    public func load(_ tab: YouTubeTab, sort: YouTubeVideoSort, channel: UID?) async {
        switch tab {
        case .videos, .unwatched:
            let youTube = youTube
            let unwatched = tab == .unwatched
            let pager = Pager { offset in
                let page = try await youTube.videos(
                    sort: sort, channelId: channel, unwatched: unwatched, offset: offset)
                return (page.items, page.nextOffset)
            }
            await pager.loadMore()
            videos = pager
        case .channels: await loadChannels()
        }
    }

    /// Re-reads what is already listed without resetting it, so a watch-state
    /// change or a return from the player keeps the scroll position and focus.
    public func refresh(_ tab: YouTubeTab) async {
        switch tab {
        case .videos, .unwatched: await videos?.refresh()
        case .channels: await loadChannels()
        }
    }
}
