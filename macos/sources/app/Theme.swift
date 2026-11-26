import RabbitEarsKit
import SwiftUI

/// The canvas palette; macOS uses the system font and native controls.
enum Theme {
    static let ground = Color(hex: 0x1C1C1E)
    static let raised = Color(hex: 0x2A2A2D)
    static let card = Color(hex: 0x232326)
    static let amber = Color(hex: 0xF2B33D)
    static let green = Color(hex: 0x5BD47A)
    static let red = Color(hex: 0xFF6B6B)
    static let primary = Color(hex: 0xE8E8ED)
    static let secondary = Color(hex: 0x98989D)
    static let synopsis = Color(hex: 0xC7C7CC)
    static let hairline = Color.white.opacity(0.08)
    static let border = Color.white.opacity(0.14)

    /// A person without a headshot, in one of the profile colors.
    static func placeholder(_ id: Int64) -> Color { Color(hex: ProfilePalette.placeholder(id)) }
}

struct PrimaryButtonStyle: ButtonStyle {
    var fullWidth = false
    var height: CGFloat = 32

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Theme.ground)
            .padding(.horizontal, 14)
            .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: height)
            .background(Theme.amber.opacity(configuration.isPressed ? 0.8 : 1), in: .rect(cornerRadius: 8))
            .contentShape(.rect)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    var fullWidth = false
    var height: CGFloat = 32

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: height)
            .background(.white.opacity(configuration.isPressed ? 0.18 : 0.12), in: .rect(cornerRadius: 8))
            .contentShape(.rect)
    }
}

struct LinkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.amber)
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

struct Tag: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 11, weight: .semibold)).padding(.horizontal, 6).padding(.vertical, 2)
            .background(.white.opacity(0.14), in: .rect(cornerRadius: 4))
    }
}

struct LabeledField<Content: View>: View {
    let label: String
    var error: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 13)).foregroundStyle(Theme.secondary)
            content
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .padding(.horizontal, 12)
                .frame(height: 38)
                .background(Theme.raised, in: .rect(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(Color(hex: 0xFF6B6B)) }
        }
    }
}

struct Avatar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.displayScale) private var scale
    let account: Account
    var size: CGFloat = 120
    @State private var image: NSImage?

    var body: some View {
        Circle().fill(Color(hex: account.rgb)).frame(width: size, height: size)
            .overlay {
                if let image {
                    Image(nsImage: image).resizable().scaledToFill().clipShape(.circle)
                } else {
                    Text(account.name.prefix(1).uppercased())
                        .font(.system(size: size * 0.42, weight: .bold)).foregroundStyle(.white)
                }
            }
            .task(id: "\(account.id)/\(account.avatarUrl ?? "")") {
                let picture = await model.artwork?.avatarImage(account, maxPixel: ArtImage.pixels(size, scale))
                image = picture.map { NSImage(cgImage: $0, size: .zero) }
            }
            .accessibilityHidden(true)
    }
}

/// An item's art at a fixed aspect, never text over it. Wide tiles show a
/// movie's or show's backdrop and an episode's still.
struct ArtBlock: View {
    let item: Item
    var aspect: CGFloat = 2.0 / 3.0
    var radius: CGFloat = 6
    /// The item's own status badges unless set, as when they clear a progress bar.
    var badges: StatusBadges?
    /// Off where the art stands for a station, which is never downloaded.
    var badged = true

    var body: some View {
        Color.clear.aspectRatio(aspect, contentMode: .fit)
            .overlay { ArtImage(item: item, kind: aspect > 1 && item.kind != .episode ? .backdrop : .poster) }
            .clipShape(.rect(cornerRadius: radius))
            .accessibilityHidden(true)
            .overlay(alignment: .bottomTrailing) { if badged { badges ?? StatusBadges(id: item.id) } }
    }
}

/// Art for anything with an item id that is not a movie or show: an album,
/// artist, channel, video, playlist or collection. Square by default;
/// people's circles.
struct Art: View {
    let id: Int64
    var aspect: CGFloat = 1
    var circle = false
    var radius: CGFloat = 6
    var collection = false
    var url: String?
    var placeholder: PlaceholderKind?
    /// The badges of `id`'s own item or collection unless set, as for a song's or playlist's art.
    var badges: StatusBadges?
    /// Off where the art stands for a station, which is never downloaded.
    var badged = true

    var body: some View {
        Color.clear.aspectRatio(aspect, contentMode: .fit)
            .overlay { ArtImage(id: id, collection: collection, url: url, placeholder: placeholder) }
            .clipShape(circle ? AnyShape(Circle()) : AnyShape(.rect(cornerRadius: radius)))
            .accessibilityHidden(true)
            .overlay(alignment: .bottomTrailing) {
                if badged { badges ?? StatusBadges(id: id, scope: collection ? .collection : .item) }
            }
    }
}

struct ProgressBar: View {
    let value: Double
    var height: CGFloat = 3

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.18))
                Capsule().fill(Theme.amber).frame(width: geometry.size.width * value)
            }
        }
        .frame(height: height)
        .accessibilityLabel("\(Int(value * 100)) percent watched")
    }
}

struct AccountCard<Content: View>: View {
    var width: CGFloat = 420
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) { content }
                .padding(28)
                .frame(width: width)
                .background(Theme.card, in: .rect(cornerRadius: 14))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.ground)
    }
}
