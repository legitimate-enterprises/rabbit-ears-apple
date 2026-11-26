import RabbitEarsKit
import SwiftUI

/// The canvas palette; iOS uses the system font and native controls.
enum Theme {
    static let ground = Color(hex: 0x1C1C1E)
    static let raised = Color(hex: 0x2A2A2D)
    static let card = Color(hex: 0x232326)
    static let amber = Color(hex: 0xF2B33D)
    static let green = Color(hex: 0x5BD47A)
    static let primary = Color(hex: 0xF2F2F7)
    static let secondary = Color(hex: 0x98989D)
    static let synopsis = Color(hex: 0xC7C7CC)
    /// A tab that is not the current one.
    static let unselected = Color(hex: 0x8E8E93)
    static let error = Color(hex: 0xFF6B6B)
    static let hairline = Color.white.opacity(0.08)
    static let border = Color.white.opacity(0.14)

    /// A person without a headshot, in the server's profile palette.
    static func person(_ id: Int64) -> Color { Color(hex: ProfilePalette.placeholder(id)) }
}

struct PrimaryButtonStyle: ButtonStyle {
    var fullWidth = false
    var height: CGFloat = 44

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(Theme.ground)
            .padding(.horizontal, 18)
            .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: height)
            .background(Theme.amber.opacity(configuration.isPressed ? 0.8 : 1), in: .rect(cornerRadius: 8))
            .contentShape(.rect)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    var fullWidth = false
    var height: CGFloat = 44

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(Theme.primary)
            .padding(.horizontal, 18)
            .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: height)
            .background(.white.opacity(configuration.isPressed ? 0.2 : 0.12), in: .rect(cornerRadius: 8))
            .contentShape(.rect)
    }
}

struct LinkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.amber)
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

struct Tag: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.primary)
            .padding(.horizontal, 6).padding(.vertical, 2)
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
                .font(.system(size: 15))
                .padding(.horizontal, 12)
                .frame(height: 44)
                .background(Theme.raised, in: .rect(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(Theme.error) }
        }
    }
}

/// The profile's picture from the server when it has one, else its initial on its color.
struct Avatar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.displayScale) private var scale
    let account: Account
    var size: CGFloat = 112
    @State private var image: UIImage?

    var body: some View {
        Circle().fill(Color(hex: account.rgb)).frame(width: size, height: size)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Text(account.name.prefix(1).uppercased())
                        .font(.system(size: size * 0.41, weight: .bold)).foregroundStyle(.white)
                }
            }
            .clipShape(.circle)
            .accessibilityHidden(true)
            .task(id: "\(account.id)/\(account.avatarUrl ?? "")") {
                let bitmap = await model.artwork?.avatarImage(account, maxPixel: ArtImage.pixels(size, scale))
                image = bitmap.map(UIImage.init(cgImage:))
            }
    }
}

/// An item's art at a fixed aspect, never text over it. Wide tiles show a
/// movie's or show's backdrop and an episode's still.
struct ArtBlock: View {
    let item: Item
    var aspect: CGFloat = 2.0 / 3.0
    var radius: CGFloat = 8
    /// Off where the art stands for a station, which is never downloaded.
    var badged = true

    var body: some View {
        Color.clear.aspectRatio(aspect, contentMode: .fit)
            .overlay { ArtImage(item: item, kind: aspect > 1 && item.kind != .episode ? .backdrop : .poster) }
            .clipShape(.rect(cornerRadius: radius))
            .accessibilityHidden(true)
            .overlay(alignment: .bottomTrailing) { if badged { StatusBadges(id: item.id) } }
    }
}

/// An album, artist, channel or video image at a fixed aspect, round for people and channels, never text over it.
/// The server keeps every one of them as the item's poster.
struct ArtSquare: View {
    let id: Int64
    var aspect: CGFloat = 1
    var radius: CGFloat = 8
    var round = false
    var collection = false
    var url: String?
    var placeholder: PlaceholderKind?
    /// The badges of `id`'s own item or collection unless set, as for a song's or playlist's art.
    var badges: StatusBadges?
    /// Off where the art stands for a station, which is never downloaded.
    var badged = true

    var body: some View {
        Color.clear.aspectRatio(aspect, contentMode: .fit)
            .overlay { ArtImage(id: id, kind: .poster, collection: collection, url: url, placeholder: placeholder) }
            .clipShape(round ? AnyShape(.circle) : AnyShape(.rect(cornerRadius: radius)))
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
                Capsule().fill(.white.opacity(0.22))
                Capsule().fill(Theme.amber).frame(width: geometry.size.width * value)
            }
        }
        .frame(height: height)
        .accessibilityLabel("\(Int(value * 100)) percent watched")
    }
}

/// The scrolling column every account screen sits in, under the server's name.
struct AccountPage<Content: View>: View {
    let name: String
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                Label(name, systemImage: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 17, weight: .bold)).lineLimit(1).accessibilityLabel(name)
                VStack(alignment: .leading, spacing: 18) { content }
            }
            .padding(EdgeInsets(top: 24, leading: 16, bottom: 32, trailing: 16))
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Theme.ground)
    }
}
