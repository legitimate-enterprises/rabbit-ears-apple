import RabbitEarsAPI
import RabbitEarsKit
import SwiftUI

/// A colored circle with the person's initial, or their headshot once it
/// arrives; name and role beneath. Selecting it opens their titles.
struct PersonCircle: View {
    @Environment(AppModel.self) private var app
    @Environment(Browser.self) private var browser
    @Environment(\.displayScale) private var scale
    let id: Person.ID
    let name: String
    let detail: String?
    let hasHeadshot: Bool
    var size: CGFloat = 72
    @State private var image: NSImage?

    var body: some View {
        Button {
            browser.open(person: id)
        } label: {
            VStack(spacing: 6) {
                Headshot(name: name, color: Theme.placeholder(id), image: image, size: size)
                Text(name).font(.system(size: 12, weight: .semibold)).lineLimit(2)
                if let detail { Text(detail).font(.system(size: 11)).foregroundStyle(Theme.secondary).lineLimit(2) }
            }
            .multilineTextAlignment(.center)
            .frame(width: size + 24, alignment: .top)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(detail.map { "\(name), \($0)" } ?? name)
        .task(id: id) {
            guard hasHeadshot else { return }
            image = await headshot(app, id, size: size, scale: scale)
        }
        .onDisappear { image = nil }
    }
}

@MainActor
private func headshot(_ app: AppModel, _ id: Person.ID, size: CGFloat, scale: CGFloat) async -> NSImage? {
    await app.artwork?.headshotImage(id, maxPixel: ArtImage.pixels(size, scale)).map {
        NSImage(cgImage: $0, size: .zero)
    }
}

struct GenreTags: View {
    let item: Item

    var body: some View {
        if let genres = item.genres, !genres.isEmpty {
            HStack(spacing: 6) { ForEach(genres) { Tag(text: $0.name) } }.foregroundStyle(Theme.secondary)
        }
    }
}

/// Whether this Mac plays the file as is or the server converts it.
struct PlayabilityLine: View {
    let verdict: Components.Schemas.Verdict

    var body: some View {
        let direct = verdict == .directPlay
        Label(Format.playability(verdict), systemImage: direct ? "checkmark.circle.fill" : "bolt.fill")
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(direct ? Theme.green : Theme.amber)
    }
}

/// Cast in billing order as circles, then key crew as text.
struct CreditsSection: View {
    let credits: Credits

    var body: some View {
        if !credits.cast.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Cast").font(.system(size: 15, weight: .bold))
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(Array(credits.cast.enumerated()), id: \.offset) { _, credit in
                            PersonCircle(
                                id: credit.personId, name: credit.name, detail: credit.character,
                                hasHeadshot: credit.profilePath != nil)
                        }
                    }
                }
            }
        }
        if !credits.crew.isEmpty {
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
                ForEach(credits.crewLines, id: \.0) { job, names in KeyValue(key: job, value: names) }
            }
        }
    }
}

/// A person and every movie and show crediting them that this profile may see.
struct PersonView: View {
    @Environment(CatalogModel.self) private var model
    @Environment(AppModel.self) private var app
    @Environment(\.displayScale) private var scale
    let id: Person.ID
    @State private var found: (Person, [Item])?
    @State private var loaded = false
    @State private var image: NSImage?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if let person = found?.0, let items = found?.1 {
                    HStack(spacing: 18) {
                        Headshot(name: person.name, color: Theme.placeholder(person.id), image: image, size: 120)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(person.name).font(.system(size: 26, weight: .bold))
                            Text(items.count == 1 ? "1 title" : "\(items.count) titles")
                                .font(.system(size: 13)).foregroundStyle(Theme.secondary)
                        }
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 14, alignment: .top)], spacing: 16) {
                        ForEach(items) { Tile(item: model.catalog.item($0.id) ?? $0) }
                    }
                } else if loaded {
                    ContentUnavailableView("Not available", systemImage: "person.crop.circle.badge.questionmark")
                } else {
                    ProgressView().frame(maxWidth: .infinity).padding(40)
                }
            }
            .padding(EdgeInsets(top: 18, leading: 22, bottom: 24, trailing: 22))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .pageTitle(found?.0.name ?? "")
        .task(id: id) {
            found = await model.person(id)
            loaded = true
            if found?.0.profilePath != nil { image = await headshot(app, id, size: 120, scale: scale) }
        }
    }
}
