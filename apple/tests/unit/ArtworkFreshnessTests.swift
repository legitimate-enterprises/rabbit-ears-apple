import Foundation
import RabbitEarsAPI
import XCTest

@testable import RabbitEarsKit

#if canImport(UIKit)
    import UIKit
#else
    import AppKit
#endif

/// An image is asked for again only once its address changes; between, the copy last seen stands in.
@MainActor
final class ArtworkFreshnessTests: XCTestCase {
    func testArtSeenOnlineIsShownOfflineByAStoreMadeSince() async throws {
        let harness = DownloadHarness()
        let kept = URLCache(
            memoryCapacity: 1 << 20, diskCapacity: 16 << 20, directory: harness.directory.appending(path: "Cache"))
        try await harness.replica.write { db in
            try db.art(30, poster: ArtworkTests.address("seen"))
            try db.art(31, poster: ArtworkTests.address("unseen"))
        }
        harness.transport.headers[.eTag] = #""w500/seen.jpg""#
        harness.transport.headers[.cacheControl] = "private, max-age=31536000, immutable"
        harness.transport.routes["GET /artwork/w500/seen.jpg"] = (.ok, "seen")
        let online = await harness.artwork(kept: kept).data(30, .poster)
        XCTAssertEqual(online, Data("seen".utf8))
        harness.goOffline()
        let relaunched = harness.artwork(kept: kept)
        let poster = await relaunched.data(30, .poster)
        XCTAssertEqual(poster, Data("seen".utf8))
        let unseen = await relaunched.data(31, .poster)
        XCTAssertNil(unseen)
    }

    func testEveryKindOfItemHasItsPlaceholderAndEachPlaceholderASymbol() {
        let kinds: [ItemKind] = [.movie, .show, .season, .episode]
        XCTAssertEqual(kinds.map(PlaceholderKind.init(itemKind:)), [.movie, .show, .show, .show])
        XCTAssertEqual(PlaceholderKind.allCases.count, 11)
        for kind in PlaceholderKind.allCases {
            #if canImport(UIKit)
                XCTAssertNotNil(UIImage(systemName: kind.symbol), kind.symbol)
            #else
                XCTAssertNotNil(NSImage(systemSymbolName: kind.symbol, accessibilityDescription: nil), kind.symbol)
            #endif
        }
    }
}
