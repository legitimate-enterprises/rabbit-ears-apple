import Foundation
import HTTPTypes
import OpenAPIRuntime
import RabbitEarsAPI
import XCTest

@testable import RabbitEarsKit

#if canImport(UIKit)
    import UIKit
#else
    import AppKit
#endif

/// Serves images for items 1 and 5, 404 for 2 and 503 for 3 (uid.N ids).
final class StatusTransport: ClientTransport, @unchecked Sendable {
    var paths: [String] = []

    func send(
        _ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String
    ) async throws -> (HTTPResponse, HTTPBody?) {
        let path = request.path ?? ""
        paths.append(path)
        let item = path.split(separator: "/").dropFirst().first.flatMap { UID(String($0)) }
        let status: HTTPResponse.Status =
            item == UID.n(1) || item == UID.n(5) ? .ok : item == UID.n(3) ? .serviceUnavailable : .notFound
        var response = HTTPResponse(status: status)
        response.headerFields[.contentType] = status == .ok ? "image/jpeg" : "application/json"
        response.headerFields[.eTag] = #""w500/a.jpg""#
        response.headerFields[.cacheControl] = "private, max-age=86400"
        return (response, HTTPBody(status == .ok ? "jpg" : #"{"code":"not_found","message":"no"}"#))
    }
}

@MainActor
final class ArtworkFreshnessTests: XCTestCase {
    func testAMissingImageIsAskedForOnceButATransientFailureIsAskedAgain() async throws {
        let transport = StatusTransport()
        let store = ArtworkStore(client: ServerEndpoint.default.client(token: "tok", transport: transport))
        for _ in 0..<2 { _ = await store.data(2, .poster) }
        for _ in 0..<2 { _ = await store.data(3, .poster) }
        XCTAssertEqual(
            transport.paths,
            [
                "/items/\(UID.n(2))/artwork/poster", "/items/\(UID.n(3))/artwork/poster",
                "/items/\(UID.n(3))/artwork/poster",
            ])
    }

    func testArtSeenOnlineIsShownOfflineByAStoreMadeSince() async throws {
        let harness = DownloadHarness()
        let kept = URLCache(
            memoryCapacity: 1 << 20, diskCapacity: 16 << 20, directory: harness.directory.appending(path: "Cache"))
        harness.transport.headers[.eTag] = #""w500/a.jpg""#
        harness.transport.headers[.cacheControl] = "private, max-age=86400"
        harness.transport.routes["GET /items/\(UID.n(30))/artwork/poster"] = (.ok, "seen")
        let online = await ArtworkStore(client: harness.client, kept: kept).data(30, .poster)
        XCTAssertEqual(online, Data("seen".utf8))
        harness.goOffline()
        let relaunched = ArtworkStore(client: harness.client, kept: kept)
        let poster = await relaunched.data(30, .poster)
        XCTAssertEqual(poster, Data("seen".utf8))
        let unseen = await relaunched.data(31, .poster)
        XCTAssertNil(unseen)
    }

    func testAnImageInMemoryIsKnownToBeSoAtTheSizeItWasDecoded() async {
        let transport = ArtworkTransport()
        transport.image = ArtworkTests.png(width: 500, height: 750)
        let store = ArtworkStore(client: ServerEndpoint.default.client(token: "tok", transport: transport))
        XCTAssertNil(store.resident(1, .poster, maxPixel: 330))
        _ = await store.image(1, .poster, maxPixel: 330)
        XCTAssertNotNil(store.resident(1, .poster, maxPixel: 330))
        XCTAssertNil(store.resident(1, .poster, maxPixel: 128))
        XCTAssertNil(store.resident(1, .backdrop, maxPixel: 330))
        _ = await store.image(collection: 1, .poster, maxPixel: 330)
        XCTAssertNotNil(store.resident(collection: 1, .poster, maxPixel: 330))
        XCTAssertNil(store.resident(collection: 2, .poster, maxPixel: 330))
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
