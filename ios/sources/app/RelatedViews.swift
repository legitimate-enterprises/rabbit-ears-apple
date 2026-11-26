import RabbitEarsKit
import SwiftUI

/// Previous and Next, each only when there is one, each in place of this page.
struct NeighborButtons: View {
    @Environment(Browser.self) private var browser
    let related: ItemRelated?

    var body: some View {
        if let neighbors = related?.neighbors, !neighbors.isEmpty {
            HStack(spacing: 10) {
                ForEach(neighbors, id: \.isNext) { neighbor in
                    Button {
                        browser.replace(with: neighbor.item)
                    } label: {
                        Text(neighbor.title).lineLimit(1).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(SecondaryButtonStyle(fullWidth: true))
                    .accessibilityLabel(neighbor.accessibilityLabel)
                }
            }
        }
    }
}

/// A movie's collections, each as one of the home screen's strips.
struct RelatedStrips: View {
    let related: ItemRelated

    var body: some View {
        ForEach(related.collections, id: \.collection.id) {
            Strip(title: $0.collection.name, items: $0.items, width: 110, wide: false)
        }
    }
}
