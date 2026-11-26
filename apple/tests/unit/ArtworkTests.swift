import CoreGraphics
import Foundation
import HTTPTypes
import ImageIO
import OpenAPIRuntime
import RabbitEarsAPI
import XCTest

@testable import RabbitEarsKit

/// Answers artwork for item 1, collection 1, person 5 and profile 1 and 404 for anything else, counting requests.
final class ArtworkTransport: ClientTransport, @unchecked Sendable {
    var paths: [String] = []
    var image = Data("jpg".utf8)

    func send(
        _ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String
    ) async throws -> (HTTPResponse, HTTPBody?) {
        paths.append(request.path ?? "")
        let served = [
            "/items/1/artwork/poster", "/collections/1/artwork/poster", "/people/5/artwork", "/profiles/1/avatar",
        ]
        guard served.contains(request.path ?? "") else {
            var response = HTTPResponse(status: .notFound)
            response.headerFields[.contentType] = "application/json"
            return (response, HTTPBody(#"{"code":"not_found","message":"not found"}"#))
        }
        var response = HTTPResponse(status: .ok)
        response.headerFields[.contentType] = "image/jpeg"
        response.headerFields[.eTag] = #""w500/a.jpg""#
        response.headerFields[.cacheControl] = "private, max-age=86400"
        return (response, HTTPBody(image))
    }
}

@MainActor
final class ArtworkTests: XCTestCase {
    func testFetchesOncePerImageAndMissesQuietly() async {
        let transport = ArtworkTransport()
        let store = ArtworkStore(client: ServerEndpoint.default.client(token: "tok", transport: transport))
        let first = await store.data(1, .poster)
        let again = await store.data(1, .poster)
        let missing = await store.data(2, .backdrop)
        XCTAssertEqual(first, Data("jpg".utf8))
        XCTAssertEqual(again, first)
        XCTAssertNil(missing)
        XCTAssertEqual(transport.paths, ["/items/1/artwork/poster", "/items/2/artwork/backdrop"])
    }

    func testHeadshotsAreCachedApartFromItemArt() async {
        let transport = ArtworkTransport()
        let store = ArtworkStore(client: ServerEndpoint.default.client(token: "tok", transport: transport))
        let first = await store.headshot(5)
        let again = await store.headshot(5)
        let missing = await store.headshot(1)
        XCTAssertEqual(first, Data("jpg".utf8))
        XCTAssertEqual(again, first)
        XCTAssertNil(missing)
        XCTAssertEqual(transport.paths, ["/people/5/artwork", "/people/1/artwork"])
    }

    func testCollectionArtIsCachedApartFromItemArt() async {
        let transport = ArtworkTransport()
        let store = ArtworkStore(client: ServerEndpoint.default.client(token: "tok", transport: transport))
        let first = await store.data(collection: 1, .poster)
        let again = await store.data(collection: 1, .poster)
        let item = await store.data(1, .poster)
        let missing = await store.data(collection: 2, .backdrop)
        XCTAssertEqual(first, Data("jpg".utf8))
        XCTAssertEqual(again, first)
        XCTAssertEqual(item, first)
        XCTAssertNil(missing)
        XCTAssertEqual(
            transport.paths,
            ["/collections/1/artwork/poster", "/items/1/artwork/poster", "/collections/2/artwork/backdrop"])
    }

    func testArtIsDecodedAtTheSizeItIsShownAndOnlyOnce() async throws {
        let transport = ArtworkTransport()
        transport.image = Self.png(width: 500, height: 750)
        let store = ArtworkStore(client: ServerEndpoint.default.client(token: "tok", transport: transport))
        let decoded = await store.image(1, .poster, maxPixel: 330)
        let poster = try XCTUnwrap(decoded)
        XCTAssertEqual([poster.width, poster.height], [220, 330])
        let again = await store.image(1, .poster, maxPixel: 330)
        XCTAssertTrue(again === poster)
        let headshot = await store.headshotImage(5, maxPixel: 1000)
        let face = try XCTUnwrap(headshot)
        XCTAssertEqual([face.width, face.height], [500, 750])
        XCTAssertEqual(transport.paths, ["/items/1/artwork/poster", "/people/5/artwork"])
    }

    func testUndecodableArtIsNil() async {
        let store = ArtworkStore(client: ServerEndpoint.default.client(token: "tok", transport: ArtworkTransport()))
        let image = await store.image(1, .poster, maxPixel: 330)
        XCTAssertNil(image)
    }

    func testDecodedArtIsBoundedByCost() async throws {
        let transport = ArtworkTransport()
        transport.image = Self.png(width: 500, height: 750)
        let store = ArtworkStore(client: ServerEndpoint.default.client(token: "tok", transport: transport))
        XCTAssertGreaterThan(store.bitmaps.totalCostLimit, 0)
        let first = await store.image(1, .poster, maxPixel: 330)
        let large = try XCTUnwrap(first)
        store.bitmaps.totalCostLimit = large.bytesPerRow * large.height + 1
        _ = await store.image(1, .poster, maxPixel: 300)
        XCTAssertNil(store.bitmaps.object(forKey: "1/poster@330"))
        XCTAssertNotNil(store.bitmaps.object(forKey: "1/poster@300"))
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
            of: #""filterMode""#, with: #""avatarUrl":"/api/v1/profiles/1/avatar","filterMode""#)
        let picture = await store.avatar(Fixtures.decode(pictured, as: Account.self))
        XCTAssertEqual(picture, Data("jpg".utf8))
        XCTAssertEqual(transport.paths, ["/profiles/1/avatar"])
    }

    func testTilesDecodeInStepsOf64PixelsAndKeepAColorPerId() {
        XCTAssertEqual(ArtImage.pixels(100, 2), 256)
        XCTAssertEqual(ArtImage.pixels(96, 2), 192)
        XCTAssertEqual(ArtPalette.color(3), ArtPalette.color(Int64(3 + ArtPalette.colors.count)))
    }
}
