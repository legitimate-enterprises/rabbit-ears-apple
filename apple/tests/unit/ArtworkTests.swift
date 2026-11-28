import CoreGraphics
import Foundation
import GRDB
import HTTPTypes
import ImageIO
import OpenAPIRuntime
import RabbitEarsAPI
import XCTest

@testable import RabbitEarsKit

/// Answers any image under /artwork/ but gone.jpg (404) and down.jpg (503), and profile 1's avatar (a uid.N
/// id); 404 for anything else. Counts requests.
final class ArtworkTransport: ClientTransport, @unchecked Sendable {
    var paths: [String] = []
    var image = Data("jpg".utf8)

    func send(
        _ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String
    ) async throws -> (HTTPResponse, HTTPBody?) {
        let path = request.path ?? ""
        paths.append(path)
        let art = path.hasPrefix("/artwork/") && !path.hasSuffix("/gone.jpg") && !path.hasSuffix("/down.jpg")
        guard art || path == "/profiles/\(UID.n(1))/avatar" else {
            var response = HTTPResponse(status: path.hasSuffix("/down.jpg") ? .serviceUnavailable : .notFound)
            response.headerFields[.contentType] = "application/json"
            return (response, HTTPBody(#"{"code":"not_found","message":"not found"}"#))
        }
        var response = HTTPResponse(status: .ok)
        response.headerFields[.contentType] = "image/jpeg"
        response.headerFields[.eTag] = #""w500/a.jpg""#
        response.headerFields[.cacheControl] = "private, max-age=31536000, immutable"
        return (response, HTTPBody(image))
    }
}

@MainActor
final class ArtworkTests: XCTestCase {
    /// The address the server names for TMDB's image `name` in `store`, w500 for posters and w1280 for backdrops.
    nonisolated static func address(_ name: String, store: String = "w500") -> String {
        "/api/v2/artwork/\(store)/\(name).jpg"
    }

    /// A replica whose movie 1 has poster a.jpg and movie 2 b.jpg, seen by adult 1 and kid 2; artist 40's
    /// one album, 50, has poster e.jpg and only an explicit song, so only the adult is shown it.
    private func replica(_ rows: (Database) throws -> Void = { _ in }) throws -> Replica {
        let fixture = ReplicaFixture()
        addTeardownBlock { fixture.remove() }
        return try fixture.v1 { db in
            try db.account(1, "Avery")
            try db.account(2, "Robin", kind: "kid")
            try db.item(1, "movie", "Dune")
            try db.item(2, "movie", "Heat")
            try db.art(1, poster: "a")
            try db.art(2, poster: "b")
            try db.artist(40, "Radiohead")
            try db.album(50, "In Rainbows", artist: 40)
            try db.song(5, "Bodysnatchers", album: 50, explicit: true)
            try db.art(50, poster: "e")
            try rows(db)
        }
    }

    /// A store whose art `replica` names for `profile`, as AppModel makes one.
    static func store(
        _ transport: ArtworkTransport, _ replica: Replica, profile: UID = 1, kept: URLCache? = nil
    ) -> ArtworkStore {
        ArtworkStore(client: ServerEndpoint.default.client(token: "tok", transport: transport), kept: kept) { key in
            (try? await replica.read { try key.address(for: profile, $0) }) ?? nil
        }
    }

    func testAnImageIsFetchedOnceAtItsAddressAndServedFromMemoryAfter() async throws {
        let transport = ArtworkTransport()
        let store = Self.store(transport, try replica())
        let first = await store.data(1, .poster)
        let again = await store.data(1, .poster)
        XCTAssertEqual(first, Data("jpg".utf8))
        XCTAssertEqual(again, first)
        XCTAssertEqual(transport.paths, ["/artwork/w500/a.jpg"])
    }

    func testAChangedAddressFetchesThatImageAndNoOther() async throws {
        let transport = ArtworkTransport()
        let replica = try replica()
        let store = Self.store(transport, replica)
        _ = await store.data(1, .poster)
        _ = await store.data(2, .poster)
        try await replica.write { try $0.art(1, poster: "c") }
        _ = await store.data(1, .poster)
        _ = await store.data(2, .poster)
        XCTAssertEqual(transport.paths, ["/artwork/w500/a.jpg", "/artwork/w500/b.jpg", "/artwork/w500/c.jpg"])
    }

    func testAnUnrelatedRowChangingFetchesNothing() async throws {
        let transport = ArtworkTransport()
        let replica = try replica()
        let store = Self.store(transport, replica)
        _ = await store.data(1, .poster)
        try await replica.write { db in
            try db.execute(sql: "UPDATE item SET parsed_title = 'Dune: Part One' WHERE id = ?", arguments: [UID.n(1)])
            try db.watch(1, for: 1, position: 60_000)
            try db.item(3, "movie", "Alien")
            try db.art(3, poster: "c")
        }
        _ = await store.data(1, .poster)
        XCTAssertEqual(transport.paths, ["/artwork/w500/a.jpg"])
    }

    func testArtWithNoAddressIsNotAskedFor() async throws {
        let transport = ArtworkTransport()
        let replica = try replica()
        let none = await Self.store(transport, replica).data(1, .backdrop)
        let unseen = await Self.store(transport, replica, profile: 2).data(40, .poster)
        XCTAssertNil(none)
        XCTAssertNil(unseen, "the kid may hear none of the artist's albums")
        XCTAssertEqual(transport.paths, [])
        let adults = try await replica.read { try ArtKey(id: 40, kind: .poster).address(for: 1, $0) }
        XCTAssertEqual(adults, Self.address("e"))
    }

    func testAMissingImageIsAskedForOnceButATransientFailureIsAskedAgain() async throws {
        let transport = ArtworkTransport()
        let replica = try replica { db in
            try db.art(1, poster: "gone", backdrop: "down")
        }
        let store = Self.store(transport, replica)
        for _ in 0..<2 { _ = await store.data(1, .poster) }
        for _ in 0..<2 { _ = await store.data(1, .backdrop) }
        XCTAssertEqual(
            transport.paths, ["/artwork/w500/gone.jpg", "/artwork/w1280/down.jpg", "/artwork/w1280/down.jpg"])
    }

    func testACollectionShowingAnItemsArtSharesItsFetch() async throws {
        let transport = ArtworkTransport()
        let replica = try replica { db in
            try db.art(1, poster: "a", backdrop: "b")
            try db.collection(9, "Dune Collection", movies: [1])
        }
        let store = Self.store(transport, replica)
        let poster = await store.data(collection: 9, .poster)
        let item = await store.data(1, .poster)
        let backdrop = await store.data(collection: 9, .backdrop)
        let other = await store.data(collection: 8, .poster)
        XCTAssertEqual(poster, Data("jpg".utf8))
        XCTAssertEqual(item, poster)
        XCTAssertEqual(backdrop, poster)
        XCTAssertNil(other)
        XCTAssertEqual(transport.paths, ["/artwork/w500/a.jpg", "/artwork/w1280/b.jpg"])
    }

    func testAnAddressIsReadForTheActiveProfileAgainAfterItChanges() async throws {
        let transport = ArtworkTransport()
        let replica = try replica()
        var profile: UID = 1
        let store = ArtworkStore(client: ServerEndpoint.default.client(token: "tok", transport: transport)) { key in
            let shown = profile
            return (try? await replica.read { try key.address(for: shown, $0) }) ?? nil
        }
        transport.image = Self.png(width: 50, height: 75)
        _ = await store.image(40, .poster, maxPixel: 128)
        XCTAssertNotNil(store.resident(40, .poster, maxPixel: 128))
        profile = 2
        store.profileChanged()
        XCTAssertNil(store.resident(40, .poster, maxPixel: 128), "the adult's art is not shown to the kid")
        let kids = await store.image(40, .poster, maxPixel: 128)
        XCTAssertNil(kids)
        XCTAssertEqual(transport.paths, ["/artwork/w500/e.jpg"])
    }

    func testAHeadshotIsFetchedOnceAtTheAddressItsPersonCarries() async throws {
        let transport = ArtworkTransport()
        let store = Self.store(transport, try replica())
        let first = await store.data(imageUrl: "/api/v2/artwork/w500/c.jpg")
        let again = await store.data(imageUrl: "/api/v2/artwork/w500/c.jpg")
        let missing = await store.data(imageUrl: "/api/v2/artwork/w185/gone.jpg")
        let foreign = await store.data(imageUrl: "/api/v2/people/\(UID.n(5))/artwork")
        XCTAssertEqual(first, Data("jpg".utf8))
        XCTAssertEqual(again, first)
        XCTAssertNil(missing)
        XCTAssertNil(foreign, "only an address getArtwork serves")
        XCTAssertEqual(transport.paths, ["/artwork/w500/c.jpg", "/artwork/w185/gone.jpg"])
    }

    func testArtIsDecodedAtTheSizeItIsShownAndOnlyOnce() async throws {
        let transport = ArtworkTransport()
        transport.image = Self.png(width: 500, height: 750)
        let store = Self.store(transport, try replica())
        let decoded = await store.image(1, .poster, maxPixel: 330)
        let poster = try XCTUnwrap(decoded)
        XCTAssertEqual([poster.width, poster.height], [220, 330])
        let again = await store.image(1, .poster, maxPixel: 330)
        XCTAssertTrue(again === poster)
        let headshot = await store.image(url: Self.address("c"), maxPixel: 1000)
        let face = try XCTUnwrap(headshot)
        XCTAssertEqual([face.width, face.height], [500, 750])
        XCTAssertEqual(transport.paths, ["/artwork/w500/a.jpg", "/artwork/w500/c.jpg"])
    }

    func testAnImageInMemoryIsKnownToBeSoAtTheSizeItWasDecoded() async throws {
        let transport = ArtworkTransport()
        transport.image = Self.png(width: 500, height: 750)
        let replica = try replica { db in
            try db.collection(9, "Dune Collection", movies: [2])
            try db.execute(sql: "UPDATE collection SET poster_path = '/c.jpg' WHERE id = ?", arguments: [UID.n(9)])
        }
        let store = Self.store(transport, replica)
        XCTAssertNil(store.resident(1, .poster, maxPixel: 330))
        _ = await store.image(1, .poster, maxPixel: 330)
        XCTAssertNotNil(store.resident(1, .poster, maxPixel: 330))
        XCTAssertNil(store.resident(1, .poster, maxPixel: 128))
        XCTAssertNil(store.resident(1, .backdrop, maxPixel: 330))
        XCTAssertNil(store.resident(2, .poster, maxPixel: 330))
        _ = await store.image(collection: 9, .poster, maxPixel: 330)
        XCTAssertNotNil(store.resident(collection: 9, .poster, maxPixel: 330))
        XCTAssertNil(store.resident(collection: 8, .poster, maxPixel: 330))
    }

    func testUndecodableArtIsNil() async throws {
        let store = Self.store(ArtworkTransport(), try replica())
        let image = await store.image(1, .poster, maxPixel: 330)
        XCTAssertNil(image)
    }

    func testDecodedArtIsBoundedByCost() async throws {
        let transport = ArtworkTransport()
        transport.image = Self.png(width: 500, height: 750)
        let store = Self.store(transport, try replica())
        XCTAssertGreaterThan(store.bitmaps.totalCostLimit, 0)
        let first = await store.image(1, .poster, maxPixel: 330)
        let large = try XCTUnwrap(first)
        store.bitmaps.totalCostLimit = large.bytesPerRow * large.height + 1
        _ = await store.image(1, .poster, maxPixel: 300)
        XCTAssertNil(store.bitmaps.object(forKey: "\(Self.address("a"))@330" as NSString))
        XCTAssertNotNil(store.bitmaps.object(forKey: "\(Self.address("a"))@300" as NSString))
    }

    static func png(width: Int, height: Int) -> Data {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    func testAnAvatarIsFetchedOnlyWhenTheServerHasOne() async {
        let transport = ArtworkTransport()
        let store = ArtworkStore(client: ServerEndpoint.default.client(token: "tok", transport: transport))
        let none = await store.avatar(Fixtures.decode(Fixtures.adult, as: Account.self))
        XCTAssertNil(none)
        XCTAssertTrue(transport.paths.isEmpty)
        let pictured = Fixtures.adult.replacingOccurrences(
            of: #""filterMode""#, with: #""avatarUrl":"/api/v2/profiles/\#(UID.n(1))/avatar","filterMode""#)
        let picture = await store.avatar(Fixtures.decode(pictured, as: Account.self))
        XCTAssertEqual(picture, Data("jpg".utf8))
        XCTAssertEqual(transport.paths, ["/profiles/\(UID.n(1))/avatar"])
    }

    func testTilesDecodeInStepsOf64PixelsAndKeepAColorPerId() {
        XCTAssertEqual(ArtImage.pixels(100, 2), 256)
        XCTAssertEqual(ArtImage.pixels(96, 2), 192)
        XCTAssertEqual(ArtPalette.color(3), ArtPalette.color(.n(3 + ArtPalette.colors.count)), "by the id's last byte")
        XCTAssertNotEqual(ArtPalette.color(3), ArtPalette.color(4))
        let id = UID.new()
        XCTAssertEqual(ArtPalette.color(id), ArtPalette.color(UID(id.description)!))
    }
}
