import Foundation
import RabbitEarsAPI
import XCTest

@testable import RabbitEarsKit

/// While the server cannot be reached: the Downloaded filter goes on by
/// itself, and what is certain to fail is disabled.
@MainActor
final class OfflineModeTests: XCTestCase {
    var harness: DownloadHarness!
    var store: DownloadStore { harness.store }

    override func setUp() async throws {
        harness = DownloadHarness()
        harness.resolves["item/\(UID.n(20))"] = [Fixtures.downloadTitle(20, "movie")]
        try await harness.download(.title(20))
    }

    /// A call that finds no server, as any the apps make.
    private func goOffline() async {
        harness.goOffline()
        _ = try? await harness.client.getMe()
    }

    func testGoingOfflineSwitchesTheFilterOnOnceAndTheServersReturnOff() async {
        XCTAssertFalse(store.offline)
        await goOffline()
        XCTAssertTrue(store.offline)
        XCTAssertTrue(store.downloadedOnly)
        await goOffline()
        XCTAssertTrue(store.downloadedOnly, "a second unanswered call changes nothing")
        harness.goOnline()
        XCTAssertFalse(store.offline)
        XCTAssertFalse(store.downloadedOnly)
    }

    func testAFilterOnBeforeGoingOfflineStaysOnWhenTheServerReturns() async {
        store.downloadedOnly = true
        await goOffline()
        harness.goOnline()
        XCTAssertTrue(store.downloadedOnly)
    }

    func testAHandChangeWhileOfflineIsKeptWhenTheServerReturns() async {
        await goOffline()
        store.downloadedOnly = false
        harness.goOnline()
        XCTAssertFalse(store.downloadedOnly)

        await goOffline()
        XCTAssertTrue(store.downloadedOnly, "the next time offline switches it on again")
        store.downloadedOnly = false
        store.downloadedOnly = true
        harness.goOnline()
        XCTAssertTrue(store.downloadedOnly)
    }

    func testOfflineDisablesExactlyWhatNeedsTheServer() async {
        XCTAssertEqual(ServerAction.allCases, [.play, .download, .smartRules, .friends])
        XCTAssertEqual(ServerAction.allCases.filter { store.blocks($0, 30, profile: 1) }, [], "online, nothing")
        await goOffline()
        XCTAssertEqual(ServerAction.allCases.filter { store.blocks($0, 30, profile: 1) }, ServerAction.allCases)
        XCTAssertEqual(
            ServerAction.allCases.filter { store.blocks($0, 20, profile: 1) }, [.download, .smartRules, .friends],
            "a downloaded title still plays")
        XCTAssertTrue(store.blocks(.play, 20, profile: 2), "only for the profile whose download it is")
    }
}
