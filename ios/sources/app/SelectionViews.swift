import RabbitEarsAPI
import RabbitEarsKit
import SwiftUI

extension View {
    /// A library screen's selection: Select in the toolbar, the bar along the foot while
    /// selecting, and the selection in the environment for its tiles.
    func selecting(_ selection: Selection, _ kind: SelectKind?) -> some View {
        modifier(Selecting(selection: selection, kind: kind))
    }

    /// The list showing offers Select all its whole listing, as filtered now;
    /// `token` says when `source` reads something else.
    func selectingAll(_ source: Selection.Source, token: some Equatable = 0) -> some View {
        modifier(SelectsAll(token: token, source: source))
    }

    /// While selecting, a tap toggles the tile; otherwise its long-press menu offers Select.
    func selectable(_ id: Int64) -> some View { modifier(Selectable(id: id)) }
}

/// Select for a tile's long-press menu; nothing outside a library screen that selects.
struct SelectMenuItem: View {
    @Environment(Selection.self) private var selection: Selection?
    let id: Int64

    var body: some View {
        if let selection, !selection.active {
            Button("Select", systemImage: "checkmark.circle") {
                selection.begin()
                selection.toggle(id)
            }
        }
    }
}

private struct SelectsAll<Token: Equatable>: ViewModifier {
    @Environment(Selection.self) private var selection: Selection?
    let token: Token
    let source: Selection.Source

    func body(content: Content) -> some View {
        content
            .onAppear { selection?.source = source }
            .onChange(of: token) { selection?.source = source }
    }
}

private struct Selectable: ViewModifier {
    @Environment(Selection.self) private var selection: Selection?
    let id: Int64

    func body(content: Content) -> some View {
        if let selection, selection.active {
            let picked = selection.contains(id)
            content
                .opacity(picked ? 1 : 0.7)
                .overlay(alignment: .topLeading) {
                    Image(systemName: picked ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 22)).foregroundStyle(picked ? Theme.amber : .white)
                        .shadow(radius: 2).padding(6)
                }
                // Over the tile's own button, so a tap selects rather than opens.
                .overlay { Color.clear.contentShape(.rect).onTapGesture { selection.toggle(id) } }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(picked ? [.isButton, .isSelected] : .isButton)
                .accessibilityAction { selection.toggle(id) }
        } else {
            content
        }
    }
}

private struct Selecting: ViewModifier {
    @Environment(AppModel.self) private var app
    let selection: Selection
    let kind: SelectKind?

    func body(content: Content) -> some View {
        let offered = kind.map { $0.watches || app.activeProfile?.kind == .adult } ?? false
        content
            .environment(selection)
            .toolbar {
                if offered {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(selection.active ? "Done" : "Select") {
                            if selection.active { selection.end() } else { selection.begin() }
                        }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let kind, selection.active { SelectionBar(selection: selection, kind: kind).padding(12) }
            }
            .onChange(of: kind) { selection.end() }
    }
}

private struct SelectionBar: View {
    @Environment(AppModel.self) private var app
    @Environment(CatalogModel.self) private var catalog
    @Environment(Services.self) private var services
    @Environment(Browser.self) private var browser
    let selection: Selection
    let kind: SelectKind
    @State private var target: PlaylistTarget?

    var body: some View {
        let ids = selection.inPickOrder
        let adult = app.activeProfile?.kind == .adult
        HStack(spacing: 12) {
            Text("\(ids.count) selected").font(.system(size: 15, weight: .semibold)).lineLimit(1)
            Spacer(minLength: 0)
            selectAll
            Menu("Actions") {
                if kind.watches {
                    Button("Mark watched", systemImage: "checkmark") { run { await watched(true, ids) } }
                    Button("Mark unwatched", systemImage: "circle") { run { await watched(false, ids) } }
                }
                if adult, kind.kidsContent {
                    Button("Kids' content", systemImage: "figure.and.child.holdinghands") {
                        run { await kids(true, ids) }
                    }
                    Button("Not kids' content", systemImage: "person") { run { await kids(false, ids) } }
                }
                if adult, let list = kind.playlistKind {
                    Button("Add to playlist", systemImage: "text.badge.plus") {
                        target = PlaylistTarget(itemIds: ids, kind: list)
                    }
                    Button("Add to station", systemImage: "dot.radiowaves.left.and.right") {
                        target = PlaylistTarget(itemIds: ids, kind: list, station: true)
                    }
                }
            }
            .disabled(ids.isEmpty)
            Button("Done") { selection.end() }.fontWeight(.semibold)
        }
        .foregroundStyle(Theme.primary)
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(Theme.raised, in: .rect(cornerRadius: 14))
        .shadow(color: .black.opacity(0.4), radius: 12, y: 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Selection")
        .addToPlaylist($target)
    }

    /// Reading the pages not yet loaded shows its progress; Done cancels it.
    @ViewBuilder private var selectAll: some View {
        if selection.source != nil {
            if selection.gathering {
                ProgressView().controlSize(.small)
                Text("\(selection.loaded.formatted())").font(.system(size: 15)).monospacedDigit()
                    .foregroundStyle(Theme.secondary).accessibilityLabel("Loading, \(selection.loaded) so far")
            } else {
                Button(selection.allPicked ? "Deselect all" : "Select all") { selection.toggleAll() }
                    .font(.system(size: 15)).lineLimit(1)
            }
        }
    }

    private func run(_ action: @escaping () async -> Void) {
        Task {
            await action()
            selection.end()
            browser.revision += 1
        }
    }

    private func watched(_ watched: Bool, _ ids: [Int64]) async {
        if kind.youtube {
            try? await services.youtube.setWatched(watched, items: ids)
        } else {
            await catalog.setWatched(watched, for: ids.compactMap(catalog.catalog.item))
        }
    }

    private func kids(_ on: Bool, _ ids: [Int64]) async {
        if kind.youtube {
            try? await services.youtube.setForKids(on, channels: ids)
        } else {
            await catalog.setKidsContent(on, for: ids.compactMap(catalog.catalog.item))
        }
    }
}
