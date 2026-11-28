import RabbitEarsAPI
import RabbitEarsKit
import SwiftUI

/// One occasion: every title the profile may see in it, under the occasion's name, over its colors.
struct OccasionView: View {
    @Environment(CatalogModel.self) private var model
    let occasion: ActiveOccasion
    @State private var members: Pager<Item>?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 50) {
                Text(occasion.name).font(.system(size: 80, weight: .bold)).lineLimit(2).minimumScaleFactor(0.6)
                if let members {
                    grid(members)
                } else {
                    ProgressView().frame(maxWidth: .infinity).padding(80)
                }
            }
            .padding(Theme.safeArea)
        }
        .scrollClipDisabled()
        .background {
            ZStack {
                Theme.ground
                OccasionWash(colors: occasion.colors, wash: occasion.wash)
            }
            .ignoresSafeArea()
        }
        .ignoresSafeArea()
        .toolbar(.hidden, for: .navigationBar)
        .task(id: "\(model.profileId)/\(model.revision)") {
            let next = model.occasionMembers(occasion.id)
            members = next
            await next.loadMore()
        }
    }

    @ViewBuilder
    private func grid(_ members: Pager<Item>) -> some View {
        if members.items.isEmpty && members.done {
            Text("Nothing in this occasion yet.").font(.system(size: 34)).foregroundStyle(Theme.secondary)
        }
        LazyVGrid(columns: GridView.columns, alignment: .leading, spacing: 50) {
            ForEach(members.items) { item in
                Tile(item: model.catalog.item(item.id) ?? item)
                    .onAppear { if item.id == members.items.last?.id { Task { await members.loadMore() } } }
            }
        }
        .focusSection()
        if let error = members.error { Text(error).font(.system(size: 28)).foregroundStyle(Theme.amber) }
    }
}

/// A title's details: each occasion in season it is in, as one of the home screen's shelves of the others.
struct OccasionShelves: View {
    @Environment(CatalogModel.self) private var model
    let itemId: Item.ID
    @State private var rows: [OccasionShelf] = []

    var body: some View {
        Group {
            ForEach(rows) {
                // The shelf brings the home screen's inset, which the page's padding already gives.
                Shelf(title: $0.name, items: $0.items, wide: false).padding(.horizontal, -Theme.safeArea.leading)
            }
        }
        .task(id: itemId) {
            rows = []
            rows = await model.occasionRows(containing: itemId)
        }
    }
}
