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
        XCTAssertEqual(
            CustomImage.route("/api/v1/profiles/3/playlists/7/image?v=12")?.target,
            .playlist(profileId: 3, playlistId: 7))
        XCTAssertEqual(CustomImage.route("/api/v1/profiles/3/playlists/7/image?v=12")?.version, 12)
        XCTAssertEqual(CustomImage.route("/api/v1/stations/5/image?v=2")?.target, .station(5))
        for other in ["https://example.com/a.jpg", "/api/v1/items/1/artwork/poster", "/api/v1/stations/5/image"] {
            XCTAssertNil(CustomImage.route(other), other)
        }
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
            CustomImage.choices(entries).map(\.id), ["4/poster", "4/backdrop", "6/poster"])
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
            "PUT /profiles/1/playlists/3/image": (.ok, Fixtures.playlist(3, "Mine")),
            "PUT /stations/9/image": (.badRequest, Fixtures.fieldError("url")),
            "DELETE /stations/9/image": (.noContent, ""),
        ])
        let model = CustomImageModel(
            client: ServerEndpoint(userInput: "192.168.1.9")!.client(token: "t", transport: transport))
        let playlist = ImageTarget.playlist(profileId: 1, playlistId: 3)

        let upload = await model.set(.file(image(20, 10, as: .png)), on: playlist)
        XCTAssertTrue(upload)
        XCTAssertTrue(transport.body(.put, "/profiles/1/playlists/3/image")?.isEmpty == false)

        let pick = await model.set(.artwork(itemId: 4, kind: .backdrop), on: playlist)
        XCTAssertTrue(pick)
        let picked = transport.json(.put, "/profiles/1/playlists/3/image")
        XCTAssertEqual(picked?["itemId"] as? Int, 4)
        XCTAssertEqual(picked?["kind"] as? String, "backdrop")

        let refused = await model.set(.link(" http://10.0.0.1/a.jpg "), on: .station(9))
        XCTAssertFalse(refused)
        XCTAssertEqual(transport.json(.put, "/stations/9/image")?["url"] as? String, "http://10.0.0.1/a.jpg")
        XCTAssertEqual(model.error, "needed")

        let notImage = await model.set(.file(Data("text".utf8)), on: playlist)
        XCTAssertFalse(notImage)
        XCTAssertEqual(model.error, "That file is not an image.")

        let removed = await model.remove(from: .station(9))
        XCTAssertTrue(removed)
        XCTAssertNil(model.error)
        XCTAssertEqual(transport.paths(.delete), ["/stations/9/image"])
    }
}
