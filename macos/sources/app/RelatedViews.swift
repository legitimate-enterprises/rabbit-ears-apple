import RabbitEarsKit
import SwiftUI

/// Previous and Next, each only when there is one, each in place of this page.
struct NeighborButtons: View {
    @Environment(Browser.self) private var browser
    let related: ItemRelated?

    var body: some View {
        if let neighbors = related?.neighbors, !neighbors.isEmpty {
            Flow {
                ForEach(neighbors, id: \.isNext) { neighbor in
                    // Narrower than the narrowest details column, so a long title truncates.
                    Button {
                        browser.replace(with: neighbor.item)
                    } label: {
                        Text(neighbor.title).lineLimit(1).frame(maxWidth: 240)
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .help(neighbor.accessibilityLabel)
                    .accessibilityLabel(neighbor.accessibilityLabel)
                }
            }
        }
    }
}
