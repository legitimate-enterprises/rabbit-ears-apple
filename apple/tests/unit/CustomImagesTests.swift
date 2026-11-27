import CoreGraphics
import Foundation
import ImageIO
import RabbitEarsAPI
import UniformTypeIdentifiers
import XCTest

@testable import RabbitEarsKit

@MainActor
final class CustomImagesTests: XCTestCase {
    private func image(_ width: Int, _ height: Int, as type: UTType) -> Data {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, context.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return out as Data
    }

    func testReadsTheRoutesAnImageUrlNames() {
        let playlist = "/api/v2/profiles/\(UID.n(3))/playlists/\(UID.n(7))/image?v=\(UID.n(12))"
        XCTAssertEqual(CustomImage.route(playlist)?.target, .playlist(profileId: 3, playlistId: 7))
        XCTAssertEqual(CustomImage.route(playlist)?.version, UID.n(12).description, "the cover's id")
        XCTAssertEqual(CustomImage.route("/api/v2/stations/\(UID.n(5))/image?v=\(UID.n(2))")?.target, .station(5))
        for other in [
            "https://example.com/a.jpg", "/api/v2/items/\(UID.n(1))/artwork/poster",
            "/api/v2/stations/\(UID.n(5))/image", "/api/v2/stations/5/image?v=2",
        ] {
            XCTAssertNil(CustomImage.route(other), other)
        }
    }

    func testACustomImageIsAskedForByItsRouteAndVersion() async {
        let transport = RoutingTransport()
        let store = ArtworkStore(client: ServerEndpoint.default.client(token: "t", transport: transport))
        _ = await store.data(imageUrl: "/api/v2/profiles/\(UID.n(3))/playlists/\(UID.n(7))/image?v=\(UID.n(12))")
        XCTAssertEqual(transport.paths(.get), ["/profiles/\(UID.n(3))/playlists/\(UID.n(7))/image"])
        XCTAssertEqual(transport.sent.last?.query, "v=\(UID.n(12))")
    }

    func testOffersEachTitleOnceWithABackdropOnlyForVideo() {
        let entries = [
            Fixtures.entry(
                1, position: 0, kind: "movie", itemId: 4, objects: #""item":\#(Fixtures.item(4, "movie", "Heat"))"#),
            Fixtures.entry(
                2, position: 1, kind: "movie", itemId: 4, objects: #""item":\#(Fixtures.item(4, "movie", "Heat"))"#),
            Fixtures.entry(3, position: 2, collection: 8),
            Fixtures.entry(5, position: 3, song: 6),
        ].map { Fixtures.decode($0, as: PlaylistEntry.self) }
        XCTAssertEqual(
            CustomImage.choices(entries).map(\.id),
            ["\(UID.n(4))/poster", "\(UID.n(4))/backdrop", "\(UID.n(6))/poster"])
    }

    func testThePicksAreThePlaylistsTitlesInTheReplica() async throws {
        let synced = try SyncedReplica { db in
            try db.account(1, "Avery")
            try db.account(2, "Robin")
            try db.item(4, "movie", "Heat")
            try db.music(6, "song", "Teardrop")
            try db.playlist(3, "Mine")
            try db.entry(1, in: 3, item: 4, rank: "a0")
            try db.entry(2, in: 3, item: 6, rank: "a1")
            try db.playlist(5, "Robin's", owner: 2)
            try db.entry(3, in: 5, item: 4, rank: "a0")
        }
        defer { synced.remove() }
        let playlists = synced.playlists()
        let mine = await playlists.artChoices(of: 3)
        XCTAssertEqual(mine.map(\.id), ["\(UID.n(4))/poster", "\(UID.n(4))/backdrop", "\(UID.n(6))/poster"])
        let robins = await playlists.artChoices(of: 5)
        XCTAssertEqual(robins, [], "not the profile's to read")
        XCTAssertTrue(synced.transport.sent.isEmpty)
    }

    func testTurnsAnyImageIntoABoundedJPEGAndRefusesTheRest() throws {
        for type in [UTType.png, .heic, .tiff] {
            let jpeg = try XCTUnwrap(
                CustomImage.uploadable(image(4000, 1000, as: type), maxPixel: 1600), type.identifier)
            let source = try XCTUnwrap(CGImageSourceCreateWithData(jpeg as CFData, nil))
            XCTAssertEqual(CGImageSourceGetType(source) as String?, UTType.jpeg.identifier)
            let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            XCTAssertEqual(props?[kCGImagePropertyPixelWidth] as? Int, 1600)
        }
        XCTAssertNil(CustomImage.uploadable(Data("not an image".utf8)))
    }

    func testSetsAnUploadAPickAndALinkThenRemoves() async {
        let transport = RoutingTransport([
            "PUT /profiles/\(UID.n(1))/playlists/\(UID.n(3))/image": (.ok, Fixtures.playlist(3, "Mine")),
            "PUT /stations/\(UID.n(9))/image": (.badRequest, Fixtures.fieldError("url")),
            "DELETE /stations/\(UID.n(9))/image": (.noContent, ""),
        ])
        let model = CustomImageModel(
            client: ServerEndpoint(userInput: "192.168.1.9")!.client(token: "t", transport: transport))
        let playlist = ImageTarget.playlist(profileId: 1, playlistId: 3)

        let upload = await model.set(.file(image(20, 10, as: .png)), on: playlist)
        XCTAssertTrue(upload)
        XCTAssertTrue(transport.body(.put, "/profiles/\(UID.n(1))/playlists/\(UID.n(3))/image")?.isEmpty == false)

        let pick = await model.set(.artwork(itemId: 4, kind: .backdrop), on: playlist)
        XCTAssertTrue(pick)
        let picked = transport.json(.put, "/profiles/\(UID.n(1))/playlists/\(UID.n(3))/image")
        XCTAssertEqual(picked?["itemId"] as? String, UID.n(4).description)
        XCTAssertEqual(picked?["kind"] as? String, "backdrop")

        let refused = await model.set(.link(" http://10.0.0.1/a.jpg "), on: .station(9))
        XCTAssertFalse(refused)
        XCTAssertEqual(transport.json(.put, "/stations/\(UID.n(9))/image")?["url"] as? String, "http://10.0.0.1/a.jpg")
        XCTAssertEqual(model.error, "needed")

        let notImage = await model.set(.file(Data("text".utf8)), on: playlist)
        XCTAssertFalse(notImage)
        XCTAssertEqual(model.error, "That file is not an image.")

        let removed = await model.remove(from: .station(9))
        XCTAssertTrue(removed)
        XCTAssertNil(model.error)
        XCTAssertEqual(transport.paths(.delete), ["/stations/\(UID.n(9))/image"])
    }
}
