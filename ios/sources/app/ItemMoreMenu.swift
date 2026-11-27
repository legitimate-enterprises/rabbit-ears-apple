import RabbitEarsAPI
import RabbitEarsKit
import SwiftUI

/// More on a movie, show, season or episode: watched and Watch together,
/// and for an adult the kids' rules and Add to.
struct ItemMoreMenu: View {
    @Environment(AppModel.self) private var app
    let item: Item
    var together: WatchTogetherModel?
    var editionId: UID?
    @Binding var target: PlaylistTarget?
    var addToCollection: (() -> Void)?

    var body: some View {
        Menu {
            ItemMenuContent(
                item: item, together: together, editionId: editionId, target: $target,
                addToCollection: addToCollection)
        } label: {
            Label("More", systemImage: "ellipsis").frame(maxWidth: .infinity)
        }
        .menuStyle(.button).buttonStyle(SecondaryButtonStyle(fullWidth: true))
        // A menu's items never appear, so details reads here what a tile's menu keeps from sign-in.
        .task(id: item.id) {
            guard app.itemMenuActions(item.kind).allowList else { return }
            app.allowLists.set(await AllowedForKids.load(item.id, app), for: item.id)
        }
    }
}

/// What More on details and a title's long-press menu both show, so the two cannot drift.
struct ItemMenuContent: View {
    @Environment(AppModel.self) private var app
    @Environment(CatalogModel.self) private var model
    let item: Item
    var together: WatchTogetherModel?
    var editionId: UID?
    @Binding var target: PlaylistTarget?
    var addToCollection: (() -> Void)?

    var body: some View {
        let actions = app.itemMenuActions(item.kind)
        // A tile holds the item as it was listed; the catalog holds it as changed since.
        let current = model.catalog.item(item.id) ?? item
        Section {
            let watched = model.catalog.unwatchedCount(item.id) == 0
            Button(watched ? "Mark as unwatched" : "Mark as watched", systemImage: "checkmark") {
                Task { await model.setWatched(!watched, for: item) }
            }
            if actions.kidsRules {
                Toggle(
                    "Kids\u{2019} content",
                    isOn: Binding(
                        get: { current.kidsContent == true },
                        set: { on in Task { await model.setKidsContent(on, for: item) } }))
                if current.kidsContentOverride != nil {
                    Button("Use rating") { Task { await model.setKidsContent(nil, for: item) } }
                }
            }
        }
        if actions.allowList {
            Section("Allowed for kids on a list") {
                AllowedForKids(
                    itemId: item.id,
                    allowed: Binding(get: { app.allowLists.kids(holding: item.id) }, set: { _ in }))
            }
        }
        DownloadMenu(.item(item, editionId: editionId))
        if let together, together.current == nil, together.invite == nil {
            Button("Watch together", systemImage: "person.2") { Task { await together.open() } }
        }
        if actions.addTo {
            Section {
                AddToButtons(
                    target: $target, itemIds: [item.id], kind: PlaylistKind(holding: item.kind),
                    editionId: editionId)
                if actions.addToCollection, let addToCollection {
                    Button("Add to collection", systemImage: "rectangle.stack.badge.plus", action: addToCollection)
                }
            }
        }
    }
}

/// Where Add to playlist, Add to station and Add to collection open from a tile's menu: sheets on
/// the tab, since the tile that asked may be gone by the time one is answered.
@MainActor
@Observable
final class TitleMenuState {
    var target: PlaylistTarget?
    var collecting: UID?
}

extension View {
    func titleMenuHost() -> some View { modifier(TitleMenuHost()) }
}

private struct TitleMenuHost: ViewModifier {
    @State private var state = TitleMenuState()

    func body(content: Content) -> some View {
        content
            .environment(state)
            .addToPlaylist($state.target)
            .sheet(item: Binding(get: { state.collecting.map(Collecting.init) }, set: { state.collecting = $0?.id })) {
                AddToCollectionSheet(movieId: $0.id).presentationDetents([.medium, .large])
            }
    }

    private struct Collecting: Identifiable { let id: UID }
}

/// A title's long-press menu: Select and Play, what More on its details offers, then the tile's own.
struct ItemContextMenu: View {
    @Environment(TitleMenuState.self) private var state: TitleMenuState?
    let item: Item
    /// Nil where playing is not from here, as a station's entries.
    var play: (() -> Void)?
    var selectable = false
    var goToShow: (() -> Void)?
    var details: (() -> Void)?
    var remove: (() -> Void)?

    var body: some View {
        if selectable { SelectMenuItem(id: item.id) }
        if let play { Button("Play", systemImage: "play.fill", action: play) }
        if let details { Button("Go to details", systemImage: "info.circle", action: details) }
        if let goToShow { Button("Go to show", systemImage: "tv", action: goToShow) }
        ItemMenuContent(
            item: item,
            target: Binding(get: { state?.target }, set: { state?.target = $0 }),
            addToCollection: { state?.collecting = item.id })
        if let remove {
            Button("Remove from collection", systemImage: "minus.circle", role: .destructive, action: remove)
        }
    }
}

/// One checkbox per kid on a manual allow list, checked when their list holds the title or channel.
struct AllowedForKids: View {
    @Environment(AppModel.self) private var app
    let itemId: UID
    @Binding var allowed: Set<Account.ID>

    var body: some View {
        ForEach(app.allowListKids, id: \.id) { kid in
            Toggle(
                kid.name,
                isOn: Binding(get: { allowed.contains(kid.id) }, set: { on in Task { await set(on, kid) } }))
        }
    }

    /// Who allows it now; none when there is no kid on a list to ask about.
    static func load(_ itemId: UID, _ app: AppModel) async -> Set<Account.ID> {
        guard !app.allowListKids.isEmpty else { return [] }
        return (try? await HouseholdModel(app: app).allowedFor(itemId)) ?? []
    }

    /// A refused change leaves the box as the server has it.
    private func set(_ on: Bool, _ kid: Account) async {
        let household = HouseholdModel(app: app)
        do {
            if on {
                try await household.allow(kid, itemId)
                allowed.insert(kid.id)
            } else {
                try await household.disallow(kid, itemId)
                allowed.remove(kid.id)
            }
        } catch {}
    }
}
