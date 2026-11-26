import UIKit
import XCTest

@testable import RabbitEarsKit

@MainActor
final class BarPictureTests: XCTestCase {
    func testAPictureForTheBarIsRoundAtItsSizeAndKeepsItsColors() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let wide = UIGraphicsImageRenderer(size: CGSize(width: 128, height: 96), format: format).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 128, height: 96))
        }
        let picture = UIImage.barPicture(try XCTUnwrap(wide.cgImage), size: 32)
        XCTAssertEqual(picture.size, CGSize(width: 32, height: 32))
        XCTAssertEqual(picture.renderingMode, .alwaysOriginal)

        let bitmap = try XCTUnwrap(picture.cgImage)
        let rgba = try XCTUnwrap(
            CGContext(
                data: nil, width: bitmap.width, height: bitmap.height, bitsPerComponent: 8,
                bytesPerRow: bitmap.width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        rgba.draw(bitmap, in: CGRect(x: 0, y: 0, width: bitmap.width, height: bitmap.height))
        let bytes = try XCTUnwrap(rgba.data).assumingMemoryBound(to: UInt8.self)
        let pixel = { (column: Int, row: Int) in
            Array(UnsafeBufferPointer(start: bytes + (row * bitmap.width + column) * 4, count: 4))
        }
        XCTAssertEqual(pixel(0, 0)[3], 0, "the corner is outside the circle")
        XCTAssertEqual(pixel(bitmap.width / 2, bitmap.height / 2), [255, 0, 0, 255])
        XCTAssertEqual(pixel(bitmap.width / 2, 1)[3], 255, "the picture fills the circle's height")
    }
}
