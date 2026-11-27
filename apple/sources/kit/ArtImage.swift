import RabbitEarsAPI
import SwiftUI

#if os(iOS) || os(tvOS)
    import UIKit

    public typealias PlatformImage = UIImage

    extension Image {
        public init(platformImage: PlatformImage) { self.init(uiImage: platformImage) }
    }

    extension PlatformImage {
        static func from(_ image: CGImage) -> PlatformImage { UIImage(cgImage: image) }
    }
#else
    import AppKit

    public typealias PlatformImage = NSImage

    extension Image {
        public init(platformImage: PlatformImage) { self.init(nsImage: platformImage) }
    }

    extension PlatformImage {
        static func from(_ image: CGImage) -> PlatformImage { NSImage(cgImage: image, size: .zero) }
    }
#endif

extension Color {
    public init(hex: UInt32) {
        self.init(
            red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

/// The flat colors a tile shows until its artwork arrives, or when it has none.
public enum ArtPalette {
    public static let colors: [UInt32] = [
        0x2E6B8A, 0x6B3A2E, 0x5B6B3F, 0x4A3F5B, 0x3F5B8A, 0x5A2B2B, 0x2B5A4A, 0x8A5A2B, 0x3B3F55, 0x4C4A48,
    ]

    /// Stable per id, so a title keeps its color everywhere: a UUIDv7's last byte is random.
    public static func color(_ id: UID) -> Color { Color(hex: colors[Int(id.uuid.uuid.15) % colors.count]) }
}

/// Server artwork filling its frame, or the item's flat color until it
/// arrives or when there is none.
public struct ArtImage: View {
    @Environment(AppModel.self) private var model
    @Environment(\.displayScale) private var scale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let id: UID
    let kind: ArtworkStore.Kind
    /// `id` names a collection, whose art the server keeps apart from items'.
    let collection: Bool
    /// A playlist's or station's own image, shown in place of `id`'s art when it loads.
    let url: String?
    let placeholder: PlaceholderKind?
    @State private var image: PlatformImage?

    public init(item: Item, kind: ArtworkStore.Kind) {
        self.init(id: item.id, kind: kind, placeholder: PlaceholderKind(itemKind: item.kind))
    }

    /// Any item id: an album, artist, channel or video has artwork like a movie does.
    public init(
        id: UID, kind: ArtworkStore.Kind = .poster, collection: Bool = false, url: String? = nil,
        placeholder: PlaceholderKind? = nil
    ) {
        self.id = id
        self.kind = kind
        self.collection = collection
        self.url = url
        self.placeholder = placeholder
    }

    public var body: some View {
        GeometryReader { geometry in
            let pixels = Self.pixels(max(geometry.size.width, geometry.size.height), scale)
            ZStack {
                ArtPalette.color(id)
                if let placeholder, image == nil {
                    PlaceholderGlyph(placeholder, side: min(geometry.size.width, geometry.size.height))
                        .transition(.opacity)
                }
                if let image { Image(platformImage: image).resizable().scaledToFill().transition(.opacity) }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .task(id: "\(url ?? "")/\(collection)/\(id)/\(kind.rawValue)@\(pixels)") {
                let store = model.artwork
                var held: CGImage?
                if url == nil {
                    held =
                        collection
                        ? store?.resident(collection: id, kind, maxPixel: pixels)
                        : store?.resident(id, kind, maxPixel: pixels)
                }
                var art = held
                if art == nil, let url { art = await store?.image(url: url, maxPixel: pixels) }
                if art == nil {
                    art =
                        collection
                        ? await store?.image(collection: id, kind, maxPixel: pixels)
                        : await store?.image(id, kind, maxPixel: pixels)
                }
                let shown = art.map(PlatformImage.from)
                if held != nil || reduceMotion {
                    image = shown
                } else {
                    withAnimation(.easeIn(duration: 0.2)) { image = shown }
                }
            }
            // Off screen the bitmap is the store's to keep or evict, so a long grid stays bounded.
            .onDisappear { image = nil }
        }
    }

    /// Device pixels for a length in points, rounded up to a step of 64 so
    /// small layout changes reuse one decoded size.
    public static func pixels(_ points: CGFloat, _ scale: CGFloat) -> Int {
        Int((points * scale / 64).rounded(.up)) * 64
    }
}

/// A person's headshot in a circle of their color, or their initial until it arrives.
public struct Headshot: View {
    let name: String
    let color: Color
    let image: PlatformImage?
    let size: CGFloat

    public init(name: String, color: Color, image: PlatformImage?, size: CGFloat) {
        self.name = name
        self.color = color
        self.image = image
        self.size = size
    }

    public var body: some View {
        Circle().fill(color).frame(width: size, height: size)
            .overlay {
                if let image {
                    Image(platformImage: image).resizable().scaledToFill()
                } else {
                    Text(name.prefix(1).uppercased()).font(.system(size: size * 0.4, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            .clipShape(.circle)
            .accessibilityHidden(true)
    }
}
