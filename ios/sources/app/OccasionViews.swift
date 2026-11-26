import RabbitEarsAPI
import RabbitEarsKit
import SwiftUI

/// One occasion: every title the profile may see in it, under the occasion's name, over its colours.
struct OccasionView: View {
    @Environment(CatalogModel.self) private var model
    let occasion: ActiveOccasion
    @State private var members: Pager<Item>?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if let members {
                    if members.items.isEmpty && members.done { EmptyNote(text: "Nothing in this occasion yet.") }
                    LazyVGrid(columns: GridView.columns, spacing: 14) {
                        ForEach(members.items) { item in
                            Tile(item: model.catalog.item(item.id) ?? item)
                                .onAppear { if item.id == members.items.last?.id { Task { await members.loadMore() } } }
                        }
                    }
                    if let error = members.error { ErrorNote(text: error) { Task { await members.loadMore() } } }
                } else {
                    ProgressView().frame(maxWidth: .infinity).padding(40)
                }
            }
            .padding(EdgeInsets(top: 4, leading: 16, bottom: 20, trailing: 16))
        }
        .background {
            ZStack {
                Theme.ground
                OccasionWash(colors: occasion.colors)
            }
            .ignoresSafeArea()
        }
        .navigationTitle(occasion.name)
        .navigationBarTitleDisplayMode(.inline)
        .pulling { await members?.refresh(reporting: true) }
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
            ForEach(rows) { Strip(title: $0.name, items: $0.items, width: 110, wide: false) }
        }
        .task(id: itemId) {
            rows = []
            rows = await model.occasionRows(containing: itemId)
        }
    }
}
