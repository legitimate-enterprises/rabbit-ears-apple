import AppKit
import RabbitEarsAPI
import RabbitEarsKit
import SwiftUI

/// Nothing when the profile has no action for the kind.
struct SelectButton: View {
    @Environment(AppModel.self) private var app
    let selection: Selection
    let kind: SelectKind

    var body: some View {
        if kind.watches || app.isAdult {
            Button(selection.active ? "Done" : "Select") {
                if selection.active { selection.end() } else { selection.begin() }
            }
            .buttonStyle(SecondaryButtonStyle())
            .accessibilityAddTraits(selection.active ? .isSelected : [])
        }
    }
}

extension View {
    /// In selection mode a click toggles the tile and a Shift-click takes the range from the last click.
    func selectable(_ selection: Selection, _ id: UID, in order: [UID]) -> some View {
        modifier(Selectable(selection: selection, id: id, order: order))
    }

    func selectionBar(_ selection: Selection, _ kind: SelectKind, order: [UID]) -> some View {
        safeAreaInset(edge: .bottom) {
            if selection.active { SelectionBar(selection: selection, kind: kind, order: order).padding(12) }
        }
    }
}

private struct Selectable: ViewModifier {
    let selection: Selection
    let id: UID
    let order: [UID]

    func body(content: Content) -> some View {
        if selection.active {
            let picked = selection.contains(id)
            content
                .opacity(picked ? 1 : 0.7)
                .overlay(alignment: .topLeading) {
                    Image(systemName: picked ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 18)).foregroundStyle(picked ? Theme.amber : .white)
                        .shadow(radius: 2).padding(6)
                }
                // Over the tile's own button, so a click selects rather than opens.
                .overlay {
                    Color.clear.contentShape(.rect).onTapGesture {
                        if NSEvent.modifierFlags.contains(.shift) {
                            selection.extend(to: id, in: order)
                        } else {
                            selection.toggle(id)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(picked ? [.isButton, .isSelected] : .isButton)
                .accessibilityAction { selection.toggle(id) }
        } else {
            content
        }
    }
}

/// The count and each action the selection's kind allows this profile, one request each.
private struct SelectionBar: View {
    @Environment(AppModel.self) private var app
    @Environment(CatalogModel.self) private var catalog
    @Environment(PlaylistsModel.self) private var playlists: PlaylistsModel?
    @Environment(StationsModel.self) private var stations: StationsModel?
    @Environment(Browser.self) private var browser
    let selection: Selection
    let kind: SelectKind
    let order: [UID]

    var body: some View {
        let ids = selection.ordered(order)
        HStack(spacing: 8) {
            Text("\(ids.count) selected").font(.system(size: 13, weight: .semibold)).fixedSize()
            Spacer()
            // Ahead of the spacer, so the actions wrap only once they cannot share one line.
            Flow(spacing: 8) {
                Button("Select all") { selection.selectAll(order) }.keyboardShortcut("a", modifiers: .command)
                Group {
                    if kind.watches {
                        Button("Mark watched") { run { await watched(true, ids) } }
                        Button("Mark unwatched") { run { await watched(false, ids) } }
                    }
                    if app.isAdult, kind.kidsContent {
                        Button("Kids' content") { run { await kids(true, ids) } }
                        Button("Not kids' content") { run { await kids(false, ids) } }
                    }
                    if app.isAdult, let list = kind.playlistKind {
                        if let playlists {
                            Menu("Add to playlist") {
                                ForEach(playlists.editable(list), id: \.id) { playlist in
                                    Button(playlist.name) { run { await playlists.add(ids, to: playlist.id) } }
                                }
                                if !playlists.editable(list).isEmpty { Divider() }
                                Button("New playlist…") {
                                    browser.naming = PlaylistNameRequest(kind: list, itemIds: ids)
                                    selection.end()
                                }
                            }
                            .menuStyle(.button).menuIndicator(.hidden).fixedSize()
                        }
                        if let stations, let playlists, !stations.mine(list).isEmpty {
                            Menu("Add to station") {
                                ForEach(stations.mine(list)) { station in
                                    Button(station.name) { run { await playlists.add(ids, to: station.playlistId) } }
                                }
                            }
                            .menuStyle(.button).menuIndicator(.hidden).fixedSize()
                        }
                    }
                }
                .disabled(ids.isEmpty)
                Button("Done") { selection.end() }.keyboardShortcut(.cancelAction).buttonStyle(PrimaryButtonStyle())
            }
            .layoutPriority(1)
        }
        .buttonStyle(SecondaryButtonStyle())
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Theme.card, in: .rect(cornerRadius: 10))
        .shadow(color: .black.opacity(0.4), radius: 12, y: 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Selection")
    }

    private func run(_ action: @escaping () async -> Void) {
        Task {
            await action()
            selection.end()
            browser.revision += 1
        }
    }

    private func watched(_ watched: Bool, _ ids: [UID]) async {
        switch kind {
        case .channel, .video:
            do { try await app.youtubeModel?.setWatched(watched, items: ids) } catch {
                app.live.say(error.localizedDescription)
            }
        default: await catalog.setWatched(watched, for: ids.compactMap(catalog.catalog.item))
        }
    }

    private func kids(_ on: Bool, _ ids: [UID]) async {
        switch kind {
        case .channel:
            do { try await app.youtubeModel?.setForKids(on, channels: ids) } catch {
                app.live.say(error.localizedDescription)
            }
        default: await catalog.setKidsContent(on, for: ids.compactMap(catalog.catalog.item))
        }
    }
}
