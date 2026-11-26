import Foundation
import MediaPlayer
import XCTest

@testable import RabbitEarsKit

@MainActor
final class NowPlayingTests: XCTestCase {
    func testAnAlbumWithNoArtworkIsFetchedOnce() async {
        var fetches = 0
        let center = SystemNowPlayingCenter { _ in
            fetches += 1
            return nil
        }
        let info = NowPlayingInfo(
            title: "Song 1", artist: "Radiohead", album: "In Rainbows", artworkItemId: 9, durationMs: 240_000,
            elapsedMs: 0, playing: true, shuffled: false, repeatMode: .off, stopOnly: false)
        center.show(info)
        await Task.yield()
        center.show(info)
        await Task.yield()
        XCTAssertEqual(fetches, 1)
        center.show(nil)
    }

    func testTheSystemDrawsArtworkFromAnyThread() async throws {
        let png = try XCTUnwrap(
            Data(
                base64Encoded:
                    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII="))
        let center = SystemNowPlayingCenter { _ in png }
        center.show(
            NowPlayingInfo(
                title: "Song 1", artist: "Radiohead", album: "In Rainbows", artworkItemId: 9, durationMs: nil,
                elapsedMs: 0, playing: true, shuffled: false, repeatMode: .off, stopOnly: false))
        var art: MPMediaItemArtwork?
        for _ in 0..<100 where art == nil {
            try await Task.sleep(for: .milliseconds(10))
            art = MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtwork] as? MPMediaItemArtwork
        }
        let found = try XCTUnwrap(art)
        nonisolated(unsafe) let artwork = found
        let drawn = await Task.detached { artwork.image(at: CGSize(width: 1, height: 1)) != nil }.value
        XCTAssertTrue(drawn)
        center.show(nil)
    }
}
