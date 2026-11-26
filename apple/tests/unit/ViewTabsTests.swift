import XCTest

@testable import RabbitEarsKit

final class ViewTabsTests: XCTestCase {
    func testMoviesAndTVTabsFollowTheCanvasAndTheProfile() {
        XCTAssertEqual(GridTab.tabs(.movie, playlists: true), [.titles, .collections, .playlists, .stations])
        XCTAssertEqual(GridTab.tabs(.movie, playlists: false), [.titles, .collections, .stations])
        XCTAssertEqual(GridTab.tabs(.show, playlists: true), [.titles, .playlists, .stations])
        XCTAssertEqual(GridTab.tabs(.show, playlists: false), [.titles, .stations])
        XCTAssertEqual(GridTab.tabs(.movie, playlists: true).map { $0.title(.movie) }.first, "Movies")
        XCTAssertEqual(
            GridTab.tabs(.show, playlists: true).map { $0.title(.show) }, ["Shows", "Playlists", "Stations"])
    }

    func testMusicTabsFollowTheCanvas() {
        XCTAssertEqual(MusicTab.allCases.map(\.rawValue), ["Albums", "Artists", "Songs", "Playlists", "Stations"])
    }

    func testYouTubeTabsAreVideosAndChannelsWithUnwatchedUnderVideos() {
        XCTAssertEqual(YouTubeTab.tabs, [.videos, .channels])
        XCTAssertEqual(YouTubeTab.unwatched.tab, .videos)
        XCTAssertEqual(YouTubeTab.channels.tab, .channels)
    }
}
