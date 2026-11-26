import RabbitEarsAPI
import RabbitEarsKit
import SwiftUI

/// The movie collections the profile may see, to open; Apple TV never edits them.
struct CollectionTiles: View {
    @Environment(CollectionsModel.self) private var collections

    var body: some View {
        if collections.collections.isEmpty {
            Text("No collections yet.").font(.system(size: 30)).foregroundStyle(Theme.secondary)
                .frame(maxWidth: .infinity).padding(80)
        }
        LazyVGrid(columns: GridView.columns, alignment: .leading, spacing: 50) {
            ForEach(collections.collections) { CollectionTile(collection: $0) }
        }
        .focusSection()
        .task { await collections.load() }
    }
}

struct CollectionTile: View {
    @Environment(Browser.self) private var browser
    let collection: MovieCollection

    var body: some View {
        Button {
            browser.open(.collection(collection.id))
        } label: {
            VStack(alignment: .leading, spacing: 14) {
                ArtBlock(id: collection.id, aspect: 2 / 3, collection: true, placeholder: .collection)
                    .overlay(alignment: .bottomTrailing) { if collection.isHandOrdered { OrderBadge() } }
                VStack(alignment: .leading, spacing: 2) {
                    Text(collection.name).font(.system(size: 28, weight: .semibold)).lineLimit(2)
                    Text(collection.summary).font(.system(size: 26)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .buttonStyle(CardButtonStyle())
    }
}

/// The mark on a collection whose movies are in a hand-made order, in its artwork's bottom trailing corner.
private struct OrderBadge: View {
    var body: some View {
        Image(systemName: "arrow.up.arrow.down").font(.system(size: 15, weight: .heavy))
            .foregroundStyle(Theme.amber).frame(width: 36, height: 36)
            .background(.black.opacity(0.6), in: .circle).padding(10)
            .accessibilityLabel("In your order")
    }
}

/// A collection: its art, name and overview, then its movies in the server's order.
struct CollectionView: View {
    @Environment(CollectionsModel.self) private var collections
    @Environment(CatalogModel.self) private var model
    let id: Int64
    @State private var movies: [Item]?

    var body: some View {
        let collection = collections.collections.first { $0.id == id }
        ScrollView {
            VStack(alignment: .leading, spacing: 50) {
                if let collection {
                    HStack(alignment: .top, spacing: 56) {
                        ArtBlock(id: id, aspect: 2 / 3, radius: 16, collection: true, placeholder: .collection)
                            .overlay(alignment: .bottomTrailing) { if collection.isHandOrdered { OrderBadge() } }
                            .frame(width: 300)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(collection.name).font(.system(size: 80, weight: .bold)).lineLimit(2)
                                .minimumScaleFactor(0.6)
                            Text(collection.summary).font(.system(size: 30)).foregroundStyle(Theme.secondary)
                                .padding(.top, 12)
                            if let overview = collection.overview {
                                Text(overview).font(.system(size: 28)).foregroundStyle(Theme.synopsis).lineLimit(4)
                                    .padding(.top, 30)
                            }
                        }
                    }
                    if let movies {
                        LazyVGrid(columns: GridView.columns, alignment: .leading, spacing: 50) {
                            ForEach(movies) { Tile(item: model.catalog.item($0.id) ?? $0) }
                        }
                        .focusSection()
                    } else {
                        ProgressView().frame(maxWidth: .infinity).padding(80)
                    }
                } else {
                    Text("Not available").font(.system(size: 34)).foregroundStyle(Theme.secondary)
                }
            }
            .padding(Theme.safeArea)
        }
        .scrollClipDisabled()
        .background(Theme.ground)
        .ignoresSafeArea()
        .toolbar(.hidden, for: .navigationBar)
        .task(id: id) { movies = await collections.movies(of: id) }
    }
}

/// `Collections  A  B` under a movie's details; each opens its collection.
struct CollectionsLine: View {
    @Environment(Browser.self) private var browser
    let collections: [MovieCollection]

    var body: some View {
        HStack(spacing: 16) {
            Text("Collections").font(.system(size: 28)).foregroundStyle(Theme.secondary).padding(.trailing, 8)
            ForEach(collections) { collection in
                Button(collection.name) { browser.open(.collection(collection.id)) }
                    .buttonStyle(ChipStyle(selected: false, radius: 12))
            }
        }
        .focusSection()
    }
}
