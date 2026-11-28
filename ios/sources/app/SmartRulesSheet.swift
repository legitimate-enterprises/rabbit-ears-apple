import RabbitEarsAPI
import RabbitEarsKit
import SwiftUI

/// A request to make a smart list or edit a list's rules.
struct SmartRulesRequest: Identifiable {
    let id = UUID()
    let target: SmartTarget
}

extension View {
    /// A new list opens once made; a station's owner is asked whether to reschedule onto the new titles.
    func smartRulesSheet(browser: Browser, services: Services) -> some View {
        @Bindable var browser = browser
        return sheet(item: $browser.smartRules) { request in
            SmartRulesSheet(
                editor: SmartRulesEditor(
                    target: request.target, client: services.playlists.client, queue: services.playlists.queue,
                    profileId: services.playlists.profileId)
            ) { editor in
                await services.playlists.load()
                await services.collections.load()
                browser.revision += 1
                if let made = editor.created {
                    browser.open(editor.scope == .collection ? .collection(made) : .playlist(made))
                }
            }
            .environment(services)
        }
    }
}

/// A Form: an existing list's name, the match line, a section per group of
/// condition rows. Disabled until an existing list's rules are read, as offline.
struct SmartRulesSheet: View {
    @Environment(Services.self) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var editor: SmartRulesEditor
    @State private var rescheduling: Station?
    /// Runs once the server holds the rules, before the sheet closes.
    private let saved: (SmartRulesEditor) async -> Void

    init(editor: SmartRulesEditor, saved: @escaping (SmartRulesEditor) async -> Void = { _ in }) {
        _editor = State(initialValue: editor)
        self.saved = saved
    }

    var body: some View {
        @Bindable var editor = editor
        NavigationStack {
            Form {
                if editor.namesList {
                    Section {
                        TextField("Name", text: $editor.name)
                    } footer: {
                        if let error = editor.nameError { Text(error).foregroundStyle(Theme.error) }
                    }
                }
                Section {
                    HStack {
                        Text("Match")
                        match($editor.topMatch)
                        Text(editor.groups.count == 1 ? "of these conditions" : "of these groups")
                    }
                }
                ForEach($editor.groups) { $group in
                    Section {
                        ForEach($group.conditions) { $row in condition($row) }
                        Button("Condition", systemImage: "plus") { editor.addCondition(to: group.id) }
                            .disabled(!editor.canAddCondition)
                    } header: {
                        if editor.groups.count > 1 {
                            HStack {
                                match($group.match)
                                Text("of:")
                            }
                        }
                    }
                }
                Section {
                    Button("Group", systemImage: "plus") { editor.addGroup() }.disabled(!editor.canAddGroup)
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        if editor.usesPersonal { Text(SmartRulesEditor.personalNote) }
                        if let error = editor.error { Text(error).foregroundStyle(Theme.error) }
                    }
                }
            }
            .disabled(!editor.ready || editor.busy)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save).disabled(!editor.ready || editor.busy)
                }
            }
        }
        .task { await editor.load() }
        .rescheduleQuestion($rescheduling, services.stations) { dismiss() }
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
        .pickerStyle(.menu).labelsHidden().fixedSize()
    }

    private func condition(_ row: Binding<SmartConditionDraft>) -> some View {
        let field = row.wrappedValue.field
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Picker("Field", selection: row.field) {
                    ForEach(editor.fields, id: \.self) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                Picker("Operator", selection: row.op) {
                    ForEach(SmartOperator.choices(field.type), id: \.self) { Text($0.label(for: field)).tag($0) }
                }
                .labelsHidden()
                Spacer(minLength: 0)
                Button("Remove condition", systemImage: "minus.circle") { editor.remove(row.wrappedValue.id) }
                    .labelStyle(.iconOnly).buttonStyle(.borderless).disabled(!editor.canRemove)
            }
            .pickerStyle(.menu)
            value(row)
            if let error = editor.errors[row.wrappedValue.id] {
                Text(error).font(.system(size: 13)).foregroundStyle(Theme.error)
            }
        }
    }

    @ViewBuilder
    private func value(_ row: Binding<SmartConditionDraft>) -> some View {
        let field = row.wrappedValue.field
        switch field.type {
        case .boolean: EmptyView()
        case .text:
            HStack {
                TextField("Value", text: row.value)
                let suggestions = field.suggestions(editor.scope)
                if !suggestions.isEmpty {
                    Menu("Ratings", systemImage: "chevron.down") {
                        ForEach(suggestions, id: \.self) { rating in Button(rating) { row.wrappedValue.value = rating }
                        }
                    }
                    .labelStyle(.iconOnly)
                }
            }
        case .number:
            HStack {
                TextField("Number", text: row.value).keyboardType(.numbersAndPunctuation)
                if let unit = field.unit { Text(unit).foregroundStyle(Theme.secondary) }
            }
        }
    }

    private func save() {
        Task {
            guard await editor.save() else { return }
            await saved(editor)
            if case .station(let station) = editor.target { rescheduling = station } else { dismiss() }
        }
    }
}

/// A new playlist's or collection's name, and Smart, off at first, to go on
/// to the rule editor, which makes the list with its rules. Offline, Smart
/// waits for the server and a plain list can still be made.
struct NewListSheet: View {
    @Environment(Browser.self) private var browser
    @Environment(\.dismiss) private var dismiss
    let title: String
    /// The rule editor's list for the name given.
    let smartTarget: (String) -> SmartTarget
    /// Makes a plain list at once.
    let create: (String) async -> Void
    @State private var name = ""
    @State private var smart = false

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                Section {
                    Toggle("Smart", isOn: $smart).needsServer(.smartRules)
                } footer: {
                    Text(SmartRulesEditor.smartNote)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        if smart {
                            browser.smartNext = SmartRulesRequest(target: smartTarget(name))
                        } else {
                            Task { await create(name) }
                        }
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }
}

/// By a smart list's name: rules choose what it holds.
struct SmartBadge: View {
    var body: some View {
        Label("Smart", systemImage: "sparkles")
            .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.primary)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(.white.opacity(0.14), in: .rect(cornerRadius: 5))
    }
}

/// On its owner's station page: Use rules asks first, as the rules replace what it holds.
struct StationRulesButton: View {
    @Environment(Browser.self) private var browser
    let station: Station
    @State private var asking = false

    var body: some View {
        Button {
            if station.smart == true {
                browser.smartRules = SmartRulesRequest(target: .station(station))
            } else {
                asking = true
            }
        } label: {
            Image(systemName: "sparkles").accessibilityLabel(station.smart == true ? "Edit rules" : "Use rules")
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
