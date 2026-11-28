import RabbitEarsAPI
import RabbitEarsKit
import SwiftUI

/// Each crew job once, in credit order, with everyone who held it.
struct CrewLines {
    let credits: Credits

    /// An episode names its directors and writers as the board does, and its guest stars.
    func lines(episode: Bool) -> [(String, String)] {
        guard episode else { return credits.crewLines }
        let renamed = ["Director": "Directed by", "Writer": "Written by"]
        var lines = credits.crewLines.map { (renamed[$0.0] ?? $0.0, $0.1) }
        if !credits.cast.isEmpty {
            lines.append(("Guest stars", credits.cast.prefix(3).map(\.name).joined(separator: ", ")))
        }
        return lines
    }
}

/// Cast in billing order as circles; each opens the person's titles.
struct CastRow: View {
    let credits: Credits

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Cast").font(.system(size: 34, weight: .bold))
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 40) {
                    ForEach(Array(credits.cast.enumerated()), id: \.offset) { _, credit in
                        PersonCircle(
                            id: credit.personId, name: credit.name, detail: credit.character,
                            headshot: credit.headshotUrl)
                    }
                }
                .padding(.vertical, 20)
            }
            .scrollClipDisabled()
        }
        .focusSection()
    }
}

/// A colored circle with the person's initial, or their headshot once it arrives; name and role beneath.
struct PersonCircle: View {
    @Environment(AppModel.self) private var app
    @Environment(Browser.self) private var browser
    let id: Person.ID
    let name: String
    let detail: String?
    let headshot: String?
    @State private var image: UIImage?

    var body: some View {
        Button {
            browser.open(person: id)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                Headshot(name: name, color: Theme.placeholder(id), image: image, size: 104)
                Text(name).font(.system(size: 26, weight: .semibold)).lineLimit(1).padding(.top, 14)
                if let detail { Text(detail).font(.system(size: 24)).foregroundStyle(.secondary).lineLimit(1) }
            }
            .frame(width: 212, alignment: .leading)
        }
        .buttonStyle(CardButtonStyle(scale: 1.06))
        .accessibilityLabel(detail.map { "\(name), \($0)" } ?? name)
        .task(id: headshot) {
            guard let headshot else { return }
            image = await app.artwork?.image(url: headshot, maxPixel: 256).map(UIImage.init(cgImage:))
        }
        .onDisappear { image = nil }
    }
}
