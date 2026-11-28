import RabbitEarsAPI
import RabbitEarsKit
import SwiftUI

/// A request to make a smart list or edit a list's rules, shown as a sheet over the whole window.
struct SmartRulesRequest: Identifiable {
    let id = UUID()
    let target: SmartTarget
}

extension View {
    /// A new list opens once made; a station's owner is asked whether to reschedule onto the new titles.
    func smartRulesSheet(browser: Browser, playlists: PlaylistsModel?, collections: CollectionsModel?) -> some View {
        @Bindable var browser = browser
        return sheet(item: $browser.smartRules) { request in
            if let playlists {
                SmartRulesSheet(
                    editor: SmartRulesEditor(
                        target: request.target, client: playlists.client, queue: playlists.queue,
                        profileId: playlists.profileId)
                ) { editor in
                    await playlists.load()
                    await collections?.load()
                    browser.revision += 1
                    if let made = editor.created {
                        browser.open(editor.scope == .collection ? .collection(made) : .playlist(made))
                    }
                    if case .station(let station) = editor.target { browser.rescheduling = station }
                }
            }
        }
    }
}

/// An existing list's name, the match line, a card per group of condition
/// rows, then Cancel and Save. Disabled until an existing list's rules are
/// read, as offline.
struct SmartRulesSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var editor: SmartRulesEditor
    /// Runs once the server holds the rules, before the sheet closes.
    private let saved: (SmartRulesEditor) async -> Void

    init(editor: SmartRulesEditor, saved: @escaping (SmartRulesEditor) async -> Void = { _ in }) {
        _editor = State(initialValue: editor)
        self.saved = saved
    }

    var body: some View {
        @Bindable var editor = editor
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.system(size: 17, weight: .bold))
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if editor.namesList {
                        LabeledField(label: "Name", error: editor.nameError) {
                            TextField("Name", text: $editor.name)
                        }
                    }
                    HStack(spacing: 8) {
                        Text("Match")
                        match($editor.topMatch)
                        Text(editor.groups.count == 1 ? "of these conditions" : "of these groups")
                    }
                    ForEach($editor.groups) { $group in card($group) }
                    Button("+ Group") { editor.addGroup() }.buttonStyle(SecondaryButtonStyle())
                        .disabled(!editor.canAddGroup)
                    if editor.usesPersonal {
                        Text(SmartRulesEditor.personalNote).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                    }
                }
                .disabled(!editor.ready || editor.busy)
            }
            .frame(maxHeight: 480)
            if let error = editor.error { Text(error).font(.system(size: 12)).foregroundStyle(Theme.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(SecondaryButtonStyle())
                Button("Save", action: save).buttonStyle(PrimaryButtonStyle()).disabled(!editor.ready || editor.busy)
            }
        }
        .padding(24).frame(width: 660)
        .background(Theme.card)
        .task { await editor.load() }
    }

    private var title: String {
        switch editor.target {
        case .newPlaylist: "New smart playlist"
        case .newCollection: "New smart collection"
        case .station: "Station rules"
        case .playlist, .collection: "Edit rules"
        }
    }

    private func match(_ selection: Binding<SmartMatch>) -> some View {
        Picker("Match", selection: selection) {
            ForEach(SmartMatch.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }
        .labelsHidden().fixedSize()
    }

    private func card(_ group: Binding<SmartGroupDraft>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if editor.groups.count > 1 {
                HStack(spacing: 8) {
                    match(group.match)
                    Text("of:")
                }
            }
            ForEach(group.conditions) { $row in condition($row) }
            Button("+ Condition") { editor.addCondition(to: group.wrappedValue.id) }
                .buttonStyle(.borderless).disabled(!editor.canAddCondition)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.raised, in: .rect(cornerRadius: 8))
    }

    private func condition(_ row: Binding<SmartConditionDraft>) -> some View {
        let field = row.wrappedValue.field
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Picker("Field", selection: row.field) {
                    ForEach(editor.fields, id: \.self) { Text($0.label).tag($0) }
                }
                .labelsHidden().frame(width: 150)
                Picker("Operator", selection: row.op) {
                    ForEach(SmartOperator.choices(field.type), id: \.self) { Text($0.label(for: field)).tag($0) }
                }
                .labelsHidden().frame(width: 150)
                value(row)
                Button {
                    editor.remove(row.wrappedValue.id)
                } label: {
                    Image(systemName: "minus")
                }
                .buttonStyle(.borderless).disabled(!editor.canRemove).accessibilityLabel("Remove condition")
            }
            if let error = editor.errors[row.wrappedValue.id] {
                Text(error).font(.system(size: 12)).foregroundStyle(Theme.red)
            }
        }
    }

    @ViewBuilder
    private func value(_ row: Binding<SmartConditionDraft>) -> some View {
        let field = row.wrappedValue.field
        switch field.type {
        case .boolean: Spacer()
        case .text:
            TextField("Value", text: row.value).textFieldStyle(.roundedBorder)
            let suggestions = field.suggestions(editor.scope)
            if !suggestions.isEmpty {
                Menu {
                    ForEach(suggestions, id: \.self) { rating in Button(rating) { row.wrappedValue.value = rating } }
                } label: {
                    Image(systemName: "chevron.down")
                }
                .menuIndicator(.hidden).fixedSize().accessibilityLabel("Ratings")
            }
        case .number:
            TextField("Number", text: row.value).textFieldStyle(.roundedBorder)
            if let unit = field.unit { Text(unit).foregroundStyle(Theme.secondary) }
        }
    }

    private func save() {
        Task {
            guard await editor.save() else { return }
            await saved(editor)
            dismiss()
        }
    }
}

extension PlaylistNameRequest {
    /// Something to add, or a rename, is never smart, as rules alone fill a smart list.
    var offersSmart: Bool { renaming == nil && itemId == nil && collectionId == nil && itemIds.isEmpty }

    /// With Smart on, Create hands the name and kind to the rule editor, which
    /// makes the list with its rules and asks neither again; nil makes a plain
    /// one at once, or nothing for a blank name.
    func smartRules(named name: String, smart: Bool) -> SmartRulesRequest? {
        guard smart, offersSmart, !name.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return SmartRulesRequest(target: .newPlaylist(name: name, kind: kind))
    }
}

extension CollectionNameRequest {
    /// A movie to add, or a rename, is never smart, as rules alone fill a smart collection.
    var offersSmart: Bool { renaming == nil && movieId == nil }

    /// As a new playlist's, without a kind.
    func smartRules(named name: String, smart: Bool) -> SmartRulesRequest? {
        guard smart, offersSmart, !name.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return SmartRulesRequest(target: .newCollection(name: name))
    }
}

/// A new list's Smart toggle and what it means; offline it waits for the server.
struct SmartToggle: View {
    @Binding var isOn: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Smart", isOn: $isOn).toggleStyle(.switch).needsServer(.smartRules)
            Text(SmartRulesEditor.smartNote).font(.system(size: 12)).foregroundStyle(Theme.secondary)
        }
    }
}

/// By a smart list's name: rules choose what it holds.
struct SmartBadge: View {
    var body: some View {
        Label("Smart", systemImage: "sparkles")
            .font(.system(size: 12, weight: .semibold)).padding(.horizontal, 8).padding(.vertical, 3)
            .background(.white.opacity(0.14), in: .rect(cornerRadius: 5))
    }
}

/// On its owner's station page: Use rules… asks first, as the rules replace what it holds.
struct StationRulesButton: View {
    @Environment(Browser.self) private var browser
    let station: Station
    @State private var asking = false

    var body: some View {
        Button(station.smart == true ? "Edit rules…" : "Use rules…") {
            if station.smart == true {
                browser.smartRules = SmartRulesRequest(target: .station(station))
            } else {
                asking = true
            }
        }
        .buttonStyle(SecondaryButtonStyle())
        .needsServer(.smartRules)
        .confirmationDialog("Use rules for this station?", isPresented: $asking, titleVisibility: .visible) {
            Button("Use rules…") { browser.smartRules = SmartRulesRequest(target: .station(station)) }
        } message: {
            Text("Replaces this station's titles with those the rules match.")
        }
    }
}
