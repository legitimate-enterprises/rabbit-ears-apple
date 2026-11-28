import RabbitEarsAPI
import RabbitEarsKit
import SwiftUI

/// The title's star, then details' More menu: watch state and, for an adult, who may see the title;
/// then Add to playlist, Add to station, Add to collection and Download.
struct DetailMoreMenu: View {
    @Environment(AppModel.self) private var app
    let item: Item
    var editionId: UID?

    var body: some View {
        FavoriteButton(id: item.id)
        Menu {
            ItemMenuContent(item: item, editionId: editionId)
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.button).menuIndicator(.hidden).buttonStyle(SecondaryButtonStyle()).fixedSize()
        .accessibilityLabel("More")
        // A menu's items never appear, so details reads here what a tile's menu keeps from sign-in.
        .task(id: item.id) {
            guard app.itemMenuActions(item.kind).allowList else { return }
            app.allowLists.set(await AllowedForKids.load(item.id, app), for: item.id)
        }
    }
}

/// What More on details and a title's right-click menu both show, so the two cannot drift.
struct ItemMenuContent: View {
    @Environment(CatalogModel.self) private var model
    @Environment(AppModel.self) private var app
    let item: Item
    var editionId: UID?
    /// In a tile's or row's menu, which alone offers Favorites: details have their star.
    var onTile = false

    var body: some View {
        let actions = app.itemMenuActions(item.kind, onTile: onTile)
        // A tile holds the item as it was listed; the catalog holds it as changed since.
        let current = model.catalog.item(item.id) ?? item
        let watched = model.catalog.unwatchedCount(item.id) == 0
        Button(watched ? "Mark as unwatched" : "Mark as watched") {
            Task { await model.setWatched(!watched, for: item) }
        }
        if model.catalog.isInProgress(item.id) {
            Button("Dismiss") { Task { await model.dismiss(item) } }
        }
        if actions.favorite { FavoriteMenuItem(id: item.id) }
        if actions.kidsRules {
            Toggle(
                "Kids' content",
                isOn: Binding(
                    get: { current.kidsContent == true },
                    set: { on in Task { await model.setKidsContent(on, for: item) } }))
            if current.kidsContentOverride != nil {
                Button("Use rating") { Task { await model.setKidsContent(nil, for: item) } }
            }
        }
        if actions.allowList {
            AllowedForKids(
                itemId: item.id,
                allowed: Binding(
                    get: { app.allowLists.kids(holding: item.id) }, set: { app.allowLists.set($0, for: item.id) }))
        }
        Divider()
        PlaylistMenu(itemId: item.id, editionId: editionId, kind: PlaylistKind(holding: item.kind))
        if actions.addToCollection { CollectionMenu(movieId: item.id) }
        DownloadMenu(.item(item, editionId: editionId))
    }
}

/// A title's right-click menu: Play, what More on its details offers, then the tile's own.
struct ItemContextMenu: View {
    let item: Item
    /// Nil where playing is not from here, as a station's entries.
    var play: (() -> Void)?
    var goToShow: (() -> Void)?
    var details: (() -> Void)?
    var remove: (() -> Void)?

    var body: some View {
        if let play { Button("Play", action: play).needsServer(.play, item.id) }
        if let details { Button("Go to details", action: details) }
        if let goToShow { Button("Go to show", action: goToShow) }
        ItemMenuContent(item: item, onTile: true)
        if let remove { Button("Remove from collection", action: remove) }
    }
}

/// A video's right-click menu: watched, Favorite and Download, with its channel.
struct VideoContextMenu: View {
    @Environment(Browser.self) private var browser
    @Environment(CatalogModel.self) private var catalog
    let video: YouTubeVideo

    var body: some View {
        Button("Play") { browser.play(video) }.needsServer(.play, video.id)
        Button(video.watched ? "Mark as unwatched" : "Mark as watched") {
            Task {
                await catalog.setWatched(!video.watched, for: Item(video: video))
                browser.revision += 1
            }
        }
        if video.positionMs > 0 {
            Button("Dismiss") {
                Task {
                    await catalog.dismiss(Item(video: video))
                    browser.revision += 1
                }
            }
        }
        FavoriteMenuItem(id: video.id)
        Button("Go to channel") { browser.open(.channel(video.channelId)) }
        DownloadMenu(.video(video))
    }
}

/// "Allowed for kids on a list": a checkbox per kid whose filter is an
/// allow list, checked when their list holds the title or channel. Absent
/// with no such kid. Its host loads `allowed`, since a menu's items never appear.
struct AllowedForKids: View {
    @Environment(AppModel.self) private var app
    let itemId: UID
    @Binding var allowed: Set<Account.ID>

    static func load(_ itemId: UID, _ app: AppModel) async -> Set<Account.ID> {
        guard app.isAdult, !app.allowListKids.isEmpty else { return [] }
        return (try? await HouseholdModel(app: app).allowedFor(itemId)) ?? []
    }

    var body: some View {
        let kids = app.allowListKids
        if !kids.isEmpty {
            Section("Allowed for kids on a list") {
                ForEach(kids) { kid in
                    Toggle(kid.name, isOn: Binding(get: { allowed.contains(kid.id) }, set: { set($0, kid) }))
                }
            }
        }
    }

    private func set(_ allow: Bool, _ kid: Account) {
        Task {
            let household = HouseholdModel(app: app)
            do {
                if allow { try await household.allow(kid, itemId) } else { try await household.disallow(kid, itemId) }
                if allow { allowed.insert(kid.id) } else { allowed.remove(kid.id) }
            } catch {
                allowed = await Self.load(itemId, app)
            }
        }
    }
}
