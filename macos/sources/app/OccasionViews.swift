import RabbitEarsAPI
import RabbitEarsKit
import SwiftUI

/// One occasion: every title the profile may see in it, under the occasion's name, over its colors.
struct OccasionScreen: View {
    @Environment(CatalogModel.self) private var model
    let occasion: ActiveOccasion
    @State private var members: Pager<Item>?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if let members {
                    if members.items.isEmpty && members.done {
                        Text("Nothing in this occasion yet.").foregroundStyle(Theme.secondary)
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 14, alignment: .top)], spacing: 16) {
                        ForEach(members.items) { item in
                            Tile(item: model.catalog.item(item.id) ?? item)
                                .onAppear { if item.id == members.items.last?.id { Task { await members.loadMore() } } }
                        }
                    }
                    if let error = members.error { Text(error).font(.system(size: 13)).foregroundStyle(Theme.red) }
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
            .padding(EdgeInsets(top: 18, leading: 22, bottom: 24, trailing: 22))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background { OccasionWash(colors: occasion.colors, wash: occasion.wash).ignoresSafeArea() }
        .pageTitle(occasion.name)
        .task(id: "\(model.profileId)/\(model.revision)") {
            let next = model.occasionMembers(occasion.id)
            members = next
            await next.loadMore()
        }
    }
}

/// A title's details: each occasion in season it is in, as one of the home screen's strips of the others.
struct OccasionStrips: View {
    @Environment(CatalogModel.self) private var model
    let itemId: Item.ID
    @State private var rows: [OccasionShelf] = []

    var body: some View {
        Group {
            ForEach(rows) { Strip(title: $0.name, items: $0.items, wide: false) }
        }
        .task(id: itemId) {
            rows = []
            rows = await model.occasionRows(containing: itemId)
        }
    }
}
