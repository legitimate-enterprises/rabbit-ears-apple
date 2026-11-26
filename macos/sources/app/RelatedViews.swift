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
                    Button(neighbor.title) { browser.replace(with: neighbor.item) }
                        .buttonStyle(SecondaryButtonStyle()).lineLimit(1)
                        .help(neighbor.accessibilityLabel)
                        .accessibilityLabel(neighbor.accessibilityLabel)
                }
            }
        }
    }
}
