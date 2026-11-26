import RabbitEarsKit
import SwiftUI

/// The canvas palette and the ten-foot metrics; sizes are points on a
/// 1920 by 1080 screen, as drawn on the boards.
enum Theme {
    static let ground = Color(hex: 0x1C1C1E)
    static let light = Color(hex: 0xF2F2F7)
    static let tabText = Color(hex: 0xD1D1D6)
    static let bar = Color(hex: 0x48484C).opacity(0.7)
    static let card = Color(hex: 0x232326)
    static let amber = Color(hex: 0xF2B33D)
    static let green = Color(hex: 0x5BD47A)
    static let secondary = Color(hex: 0x98989D)
    static let synopsis = Color(hex: 0xC7C7CC)
    static let control = Color.white.opacity(0.12)
    /// Overscan margin every screen keeps its content inside.
    static let safeArea = EdgeInsets(top: 60, leading: 80, bottom: 60, trailing: 80)

    /// A person without a headshot, in one of the profile colors.
    static func placeholder(_ id: Int64) -> Color { Color(hex: ProfilePalette.placeholder(id)) }
}

/// The canvas focus treatment in place of the system's.
struct FocusLift: ViewModifier {
    @Environment(\.isFocused) private var focused
    var scale: CGFloat = 1.08
    var fills = true
    var radius: CGFloat?

    func body(content: Content) -> some View {
        content
            .foregroundStyle(focused && fills ? Theme.ground : Theme.light)
            .background {
                if focused && fills {
                    if let radius {
                        RoundedRectangle(cornerRadius: radius).fill(Theme.light)
                    } else {
                        Capsule().fill(Theme.light)
                    }
                }
            }
            .scaleEffect(focused ? scale : 1)
            .shadow(color: .black.opacity(focused ? 0.7 : 0), radius: 30, y: 26)
            .animation(.easeOut(duration: 0.15), value: focused)
    }
}

struct TabButtonStyle: ButtonStyle {
    let current: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 26, weight: .semibold))
            .foregroundStyle(current ? .white : Theme.tabText)
            .padding(.horizontal, 26)
            .frame(height: 56)
            .background(.white.opacity(current ? 0.26 : 0), in: .capsule)
            .modifier(FocusLift())
    }
}

/// No fill under focus, so the initial stays legible.
struct AvatarButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.modifier(FocusLift(scale: 1.14, fills: false))
    }
}

struct TVButtonStyle: ButtonStyle {
    var primary = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 30, weight: .bold))
            .labelStyle(TVLabelStyle())
            .padding(.horizontal, 32)
            .frame(minHeight: 76)
            .background(primary ? Theme.amber : Theme.control, in: .rect(cornerRadius: 12))
            .modifier(PrimaryText(primary: primary))
            .modifier(FocusLift(scale: 1.06, fills: !primary, radius: 12))
    }

    /// Dark text on goldenrod, whatever FocusLift sets beneath it.
    private struct PrimaryText: ViewModifier {
        let primary: Bool
        func body(content: Content) -> some View {
            if primary { content.foregroundStyle(Theme.ground) } else { content }
        }
    }
}

struct TVLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 16) {
            configuration.icon.font(.system(size: 24, weight: .bold))
            configuration.title
        }
    }
}

struct CardButtonStyle: ButtonStyle {
    var scale: CGFloat = 1.1

    func makeBody(configuration: Configuration) -> some View {
        configuration.label.modifier(FocusLift(scale: scale, fills: false))
    }
}

struct RowButtonStyle: ButtonStyle {
    var radius: CGFloat = 20
    var scale: CGFloat = 1.03

    func makeBody(configuration: Configuration) -> some View {
        configuration.label.modifier(FocusLift(scale: scale, radius: radius))
    }
}

struct Tag: View {
    let text: String

    var body: some View {
        Text(text).font(.system(size: 24, weight: .bold)).foregroundStyle(Theme.light)
            .padding(.horizontal, 10).padding(.vertical, 2)
            .background(.white.opacity(0.18), in: .rect(cornerRadius: 6))
    }
}

struct NewBadge: View {
    let count: Int

    var body: some View {
        Text("\(count) new").font(.system(size: 24, weight: .bold)).foregroundStyle(Theme.ground)
            .padding(.horizontal, 12).padding(.vertical, 2).background(Theme.amber, in: .capsule).padding(10)
    }
}

struct Brand: View {
    let name: String

    var body: some View {
        HStack(spacing: 16) {
            RabbitEarsMark().stroke(Theme.amber, style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                .frame(width: 30, height: 34)
            Text(name).font(.system(size: 30, weight: .bold)).foregroundStyle(Theme.light).lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(name)
    }
}

/// Two antennas over a set.
struct RabbitEarsMark: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let middle = CGPoint(x: rect.midX, y: rect.height * 0.58)
        path.move(to: CGPoint(x: rect.width * 0.12, y: 0))
        path.addLine(to: middle)
        path.addLine(to: CGPoint(x: rect.width * 0.88, y: 0))
        path.addRoundedRect(
            in: CGRect(x: 0, y: rect.height * 0.58, width: rect.width, height: rect.height * 0.42),
            cornerSize: CGSize(width: 5, height: 5))
        return path
    }
}

struct Avatar: View {
    @Environment(AppModel.self) private var app
    @Environment(\.displayScale) private var scale
    let account: Account
    var size: CGFloat = 200
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
            .task(id: account.avatarUrl) {
                image = await app.artwork?.avatarImage(account, maxPixel: Int(size * scale))
                    .map(UIImage.init(cgImage:))
            }
    }
}

/// Wide tiles show a movie's or show's backdrop and an episode's still.
struct ArtBlock: View {
    let id: Int64
    let kind: ArtworkStore.Kind
    let aspect: CGFloat
    let radius: CGFloat
    /// `id` is a collection's, whose art has its own address.
    var collection = false
    var url: String?
    var placeholder: PlaceholderKind?

    init(item: Item, aspect: CGFloat = 2.0 / 3.0, radius: CGFloat = 12) {
        self.init(
            id: item.id, aspect: aspect, radius: radius,
            kind: aspect > 1 && item.kind != .episode ? .backdrop : .poster,
            placeholder: PlaceholderKind(itemKind: item.kind))
    }

    /// Music and YouTube art is always the poster.
    init(
        id: Int64, aspect: CGFloat = 1, radius: CGFloat = 12, kind: ArtworkStore.Kind = .poster,
        collection: Bool = false, url: String? = nil, placeholder: PlaceholderKind? = nil
    ) {
        self.id = id
        self.kind = kind
        self.aspect = aspect
        self.radius = radius
        self.collection = collection
        self.url = url
        self.placeholder = placeholder
    }

    var body: some View {
        Color.clear.aspectRatio(aspect, contentMode: .fit)
            .overlay { ArtImage(id: id, kind: kind, collection: collection, url: url, placeholder: placeholder) }
            .clipShape(.rect(cornerRadius: radius))
            .accessibilityHidden(true)
    }
}

struct ProgressBar: View {
    let value: Double
    var height: CGFloat = 6

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

struct AccountPage<Content: View>: View {
    let name: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Brand(name: name)
            content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(Theme.safeArea)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.ground)
        .ignoresSafeArea()
    }
}
