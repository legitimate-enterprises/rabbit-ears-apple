import RabbitEarsAPI
import XCTest

@testable import RabbitEarsKit

@MainActor
final class DownloadBadgeTests: XCTestCase {
    func testATitleIsBadgedOnTheDeviceAndAContainerWhenItsOwnRequestIsWhole() async throws {
        let harness = DownloadHarness()
        let store = harness.store
        harness.resolves["playlist/\(UID.n(3))"] = [
            Fixtures.downloadTitle(5, "song"), Fixtures.downloadTitle(6, "song"),
        ]
        try await harness.download(.playlist(3))

        XCTAssertTrue(store.badged(3, scope: .playlist, profile: 1))
        XCTAssertFalse(store.badged(3, profile: 1), "an item that shares the playlist's id is not it")
        XCTAssertFalse(store.badged(3, scope: .collection, profile: 1))
        XCTAssertTrue(store.badged(5, profile: 1), "a song is badged by itself")
        XCTAssertFalse(store.badged(3, scope: .playlist, profile: 2))

        store.ledger.titles[6]?.state = .pending
        XCTAssertFalse(store.badged(3, scope: .playlist, profile: 1), "a container waits for every title")
        XCTAssertTrue(store.badged(5, profile: 1))
    }
}
