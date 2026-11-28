import RabbitEarsAPI
import RabbitEarsKit
import SwiftUI

/// A title's long-press menu: Play and watched, which is all its details screen offers besides
/// editions and Watch together; Apple TV has no downloads, selection or kids' rules.
struct ItemContextMenu: View {
    @Environment(CatalogModel.self) private var model
    @Environment(Browser.self) private var browser
    let item: Item
    var details: (() -> Void)?

    var body: some View {
        let catalog = model.catalog
        // A show or season marks every episode under it, as on its details.
        let group = item.kind == .show || item.kind == .season
        let mark = catalog.unwatchedCount(item.id) > 0
        Button("Play", systemImage: "play.fill") { browser.play(item, in: catalog) }
        if let details { Button("Go to details", systemImage: "info.circle", action: details) }
        Button(
            group ? (mark ? "Mark all watched" : "Mark all unwatched") : (mark ? "Mark watched" : "Mark unwatched"),
            systemImage: "checkmark"
        ) {
            Task { await model.setWatched(mark, for: item) }
        }
        if FavoriteKind(rawValue: item.kind.rawValue) != nil { FavoriteMenuItem(id: item.id) }
    }
}

/// A video's long-press menu: Play and watched, as on its details.
struct VideoContextMenu: View {
    @Environment(CatalogModel.self) private var catalog
    @Environment(Browser.self) private var browser
    let video: YouTubeVideo

    var body: some View {
        Button("Play", systemImage: "play.fill") { browser.play(video) }
        Button(video.watched ? "Mark unwatched" : "Mark watched", systemImage: "checkmark") {
            Task {
                await catalog.setWatched(!video.watched, for: Item(video: video))
                browser.changed()
            }
        }
        FavoriteMenuItem(id: video.id)
    }
}
