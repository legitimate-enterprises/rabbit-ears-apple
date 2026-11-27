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

/// Serves images for items 1 and 5, 404 for 2 and 503 for 3 (uid.N ids), and names `generation` on health. An
/// image carries a generation of its own, as one answered from URLCache does.
final class GenerationTransport: ClientTransport, @unchecked Sendable {
    var paths: [String] = []
    var generation = "3"

    func send(
        _ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String
    ) async throws -> (HTTPResponse, HTTPBody?) {
        let path = request.path ?? ""
        paths.append(path)
        if path == "/health" {
            var response = HTTPResponse(status: .ok)
            response.headerFields[.contentType] = "application/json"
            response.headerFields[HTTPField.Name("Artwork-Generation")!] = generation
            return (response, HTTPBody(#"{"status":"ok","version":"1.0.0","setupRequired":false}"#))
        }
        let item = path.split(separator: "/").dropFirst().first.flatMap { UID(String($0)) }
        let status: HTTPResponse.Status =
            item == UID.n(1) || item == UID.n(5) ? .ok : item == UID.n(3) ? .serviceUnavailable : .notFound
        var response = HTTPResponse(status: status)
        response.headerFields[.contentType] = status == .ok ? "image/jpeg" : "application/json"
        response.headerFields[HTTPField.Name("Artwork-Generation")!] = "1"
        response.headerFields[.eTag] = #""w500/a.jpg""#
        response.headerFields[.cacheControl] = "private, max-age=86400"
        return (response, HTTPBody(status == .ok ? "jpg" : #"{"code":"not_found","message":"no"}"#))
    }
}

@MainActor
final class ArtworkFreshnessTests: XCTestCase {
    private func store(_ transport: GenerationTransport) -> (ArtworkStore, Client) {
        let generation = ArtworkGeneration()
        let client = ServerEndpoint.default.client(token: "tok", transport: transport, generation: generation)
        return (ArtworkStore(client: client, generation: generation), client)
    }

    func testImagesAreAskedForUnderTheGenerationTheServerLastNamedAndAgainWhenItMoves() async throws {
        let transport = GenerationTransport()
        let (store, client) = store(transport)
        _ = try await client.getHealth().ok
        _ = await store.data(1, .poster)
        _ = await store.data(5, .poster)
        _ = await store.data(1, .poster)
        transport.generation = "4"
        _ = try await client.getHealth().ok
        _ = await store.data(1, .poster)
        XCTAssertEqual(
            transport.paths.filter { $0.contains("artwork") },
            [
                "/items/\(UID.n(1))/artwork/poster?v=3", "/items/\(UID.n(5))/artwork/poster?v=3",
                "/items/\(UID.n(1))/artwork/poster?v=4",
            ])
    }

    func testACustomImageNamesNoGeneration() async throws {
        let transport = GenerationTransport()
        let (store, client) = store(transport)
        _ = try await client.getHealth().ok
        _ = try? await client.getStationImage(path: .init(stationId: 5), query: .init(v: "\(UID.n(9))"))
        _ = try? await client.getPlaylistImage(
            path: .init(profileId: 1, playlistId: 2), query: .init(v: "\(UID.n(9))"))
        _ = await store.data(1, .poster)
        XCTAssertEqual(transport.paths.last, "/items/\(UID.n(1))/artwork/poster?v=3")
    }

    func testAMissingImageIsAskedForOncePerGenerationButATransientFailureIsAskedAgain() async throws {
        let transport = GenerationTransport()
        let (store, client) = store(transport)
        _ = try await client.getHealth().ok
        for _ in 0..<2 { _ = await store.data(2, .poster) }
        for _ in 0..<2 { _ = await store.data(3, .poster) }
        XCTAssertEqual(
            Array(transport.paths.dropFirst()),
            [
                "/items/\(UID.n(2))/artwork/poster?v=3", "/items/\(UID.n(3))/artwork/poster?v=3",
                "/items/\(UID.n(3))/artwork/poster?v=3",
            ])
        transport.generation = "4"
        _ = try await client.getHealth().ok
        _ = await store.data(2, .poster)
        XCTAssertEqual(transport.paths.last, "/items/\(UID.n(2))/artwork/poster?v=4")
    }

    func testArtSeenOnlineIsShownOfflineByAStoreMadeSinceUnderNoGeneration() async throws {
        let harness = DownloadHarness()
        let kept = URLCache(
            memoryCapacity: 1 << 20, diskCapacity: 16 << 20, directory: harness.directory.appending(path: "Cache"))
        let generation = ArtworkGeneration()
        let client = harness.endpoint.client(
            token: "tok-1", transport: harness.transport, generation: generation, offline: harness.store)
        harness.transport.headers[HTTPField.Name("Artwork-Generation")!] = "3"
        harness.transport.headers[.eTag] = #""w500/a.jpg""#
        harness.transport.headers[.cacheControl] = "private, max-age=31536000, immutable"
        harness.transport.routes["GET /items/\(UID.n(30))/artwork/poster"] = (.ok, "seen")
        _ = try? await client.getHealth()
        let online = await ArtworkStore(client: client, generation: generation, kept: kept).data(30, .poster)
        XCTAssertEqual(online, Data("seen".utf8))
        XCTAssertEqual(harness.transport.queries(.get, "/items/\(UID.n(30))/artwork/poster"), ["v=3"])
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
