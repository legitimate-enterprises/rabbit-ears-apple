import RabbitEarsAPI
import RabbitEarsKit
import SwiftUI

struct PersonCircle: View {
    @Environment(AppModel.self) private var app
    @Environment(Browser.self) private var browser
    @Environment(\.displayScale) private var scale
    let id: Person.ID
    let name: String
    let detail: String?
    let hasHeadshot: Bool
    var size: CGFloat = 64
    @State private var image: UIImage?

    var body: some View {
        Button {
            browser.open(person: id)
        } label: {
            VStack(spacing: 6) {
                Headshot(name: name, color: Theme.person(id), image: image, size: size)
                Text(name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                if let detail { Text(detail).font(.system(size: 11)).foregroundStyle(Theme.secondary).lineLimit(1) }
            }
            .multilineTextAlignment(.center)
            .frame(width: size + 20, alignment: .top)
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
private func headshot(_ app: AppModel, _ id: Person.ID, size: CGFloat, scale: CGFloat) async -> UIImage? {
    await app.artwork?.headshotImage(id, maxPixel: ArtImage.pixels(size, scale)).map(UIImage.init(cgImage:))
}

struct GenreTags: View {
    let item: Item

    var body: some View {
        if let genres = item.genres, !genres.isEmpty {
            HStack(spacing: 6) { ForEach(genres.prefix(3)) { Tag(text: $0.name) } }
        }
    }
}

/// Cast in billing order as circles.
struct CastRow: View {
    let credits: Credits

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Cast").font(.system(size: 17, weight: .bold))
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(Array(credits.cast.enumerated()), id: \.offset) { _, credit in
                        PersonCircle(
                            id: credit.personId, name: credit.name, detail: credit.character,
                            hasHeadshot: credit.profilePath != nil)
                    }
                }
            }
            .contentMargins(.horizontal, 16, for: .scrollContent)
            .padding(.horizontal, -16)
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
    @State private var image: UIImage?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if let person = found?.0, let items = found?.1 {
                    VStack(spacing: 10) {
                        Headshot(name: person.name, color: Theme.person(person.id), image: image, size: 112)
                        Text(person.name).font(.system(size: 26, weight: .bold))
                        Text(items.count == 1 ? "1 title" : "\(items.count) titles")
                            .font(.system(size: 13)).foregroundStyle(Theme.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    LazyVGrid(columns: GridView.columns, spacing: 14) {
                        ForEach(items) { Tile(item: model.catalog.item($0.id) ?? $0) }
                    }
                } else if loaded {
                    ContentUnavailableView("Not available", systemImage: "person.crop.circle.badge.questionmark")
                } else {
                    ProgressView().frame(maxWidth: .infinity).padding(40)
                }
            }
            .padding(EdgeInsets(top: 4, leading: 20, bottom: 20, trailing: 20))
        }
        .background(Theme.ground)
        .navigationTitle(found?.0.name ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { BrowseToolbar() }
        .task(id: id) {
            found = await model.person(id)
            loaded = true
            if found?.0.profilePath != nil { image = await headshot(app, id, size: 112, scale: scale) }
        }
    }
}
