import RabbitEarsKit
import SwiftUI

/// Previous and Next, each only when there is one, each in place of this page.
struct NeighborButtons: View {
    @Environment(Browser.self) private var browser
    let related: ItemRelated?

    var body: some View {
        if let neighbors = related?.neighbors, !neighbors.isEmpty {
            HStack(spacing: 24) {
                ForEach(neighbors, id: \.isNext) { neighbor in
                    Button {
                        browser.replace(with: neighbor.item)
                    } label: {
                        Text(neighbor.title).lineLimit(1)
                    }
                    .buttonStyle(TVButtonStyle())
                    .accessibilityLabel(neighbor.accessibilityLabel)
                }
            }
            .padding(.top, 24)
            .focusSection()
        }
    }
}

/// A movie's collections, each as one of the home screen's shelves.
struct RelatedShelves: View {
    let related: ItemRelated

    var body: some View {
        ForEach(related.collections, id: \.collection.id) {
            // The shelf brings the home screen's inset, which the page's padding already gives.
            Shelf(title: $0.collection.name, items: $0.items, wide: false).padding(.horizontal, -Theme.safeArea.leading)
        }
    }
}
