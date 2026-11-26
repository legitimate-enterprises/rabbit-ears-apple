import UIKit

extension UIImage {
    /// A profile's picture for a bar item, which draws an image as it comes: tinted, unclipped and at its
    /// own size. So it is cut round, `size` points across and kept in its own colors.
    public static func barPicture(_ bitmap: CGImage, size: CGFloat) -> UIImage {
        let side = CGSize(width: size, height: size)
        let fill = max(size / CGFloat(bitmap.width), size / CGFloat(bitmap.height))
        let drawn = CGSize(width: CGFloat(bitmap.width) * fill, height: CGFloat(bitmap.height) * fill)
        return UIGraphicsImageRenderer(size: side).image { _ in
            UIBezierPath(ovalIn: CGRect(origin: .zero, size: side)).addClip()
            UIImage(cgImage: bitmap).draw(
                in: CGRect(
                    x: (size - drawn.width) / 2, y: (size - drawn.height) / 2, width: drawn.width, height: drawn.height)
            )
        }.withRenderingMode(.alwaysOriginal)
    }
}
