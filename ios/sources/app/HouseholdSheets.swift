import RabbitEarsAPI
import RabbitEarsKit
import SwiftUI

struct HouseholdSheetView: View {
    @Environment(\.dismiss) private var dismiss
    let sheet: HouseholdSheet
    let model: HouseholdModel

    var body: some View {
        switch sheet {
        case .edit(let kid):
            AddKidView(editing: kid, household: model, save: { try await model.saveKid(kid, $0) }, done: { dismiss() })
        case .pin(let member): PinSheet(member: member, model: model)
        case .toAdult(let kid): ChangeToAdultSheet(kid: kid, model: model)
        case .share(let member): OfferSheet(member: member, model: model)
        case .invite(let name, let invite):
            SheetPage(title: "Invite \(name)", action: nil) { InviteDetails(invite: invite) }
        }
    }
}

/// The confirming button in a sheet's navigation bar.
struct SheetAction {
    let title: String
    let disabled: Bool
    let run: () -> Void
}

struct SheetPage<Content: View>: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let action: SheetAction?
    @ViewBuilder var content: Content

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) { content }.padding(16)
            }
            .background(Theme.ground)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if let action {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(action.title, action: action.run).disabled(action.disabled)
                    }
                } else {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                }
            }
        }
    }
}

struct PinSheet: View {
    @Environment(\.dismiss) private var dismiss
    let member: Account
    let model: HouseholdModel
    @State private var pin = ""
    @State private var confirmation = ""
    @State private var error: String?

    var body: some View {
        SheetPage(
            title: member.hasPin ? "Change \(member.name)'s PIN" : "Set a PIN for \(member.name)",
            action: SheetAction(title: "Save", disabled: !valid) { save(pin) }
        ) {
            Text("Four digits, asked for when switching to \(member.name) on any device.")
                .font(.system(size: 13)).foregroundStyle(Theme.secondary)
            LabeledField(label: "PIN") {
                SecureField("", text: $pin).keyboardType(.numberPad).accessibilityLabel("PIN")
            }
            LabeledField(label: "Confirm PIN", error: mismatch ? "PINs don't match." : nil) {
                SecureField("", text: $confirmation).keyboardType(.numberPad).accessibilityLabel("Confirm PIN")
            }
            if let error { Text(error).font(.system(size: 13)).foregroundStyle(Theme.error) }
            if member.hasPin { Button("Remove PIN") { save(nil) }.buttonStyle(LinkButtonStyle()) }
        }
    }

    private var mismatch: Bool { !confirmation.isEmpty && confirmation != pin }
    private var valid: Bool { pin.count == 4 && pin.allSatisfy { $0.isASCII && $0.isNumber } && pin == confirmation }

    private func save(_ pin: String?) {
        guard pin == nil || valid else { return }
        Task {
            do {
                try await model.setPin(member, pin)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

struct ChangeToAdultSheet: View {
    let kid: Account
    let model: HouseholdModel
    @State private var email = ""
    @State private var invite: Invite?
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        if let invite {
            SheetPage(title: "Invite \(kid.name)", action: nil) { InviteDetails(invite: invite) }
        } else {
            SheetPage(
                title: "Change to adult",
                action: SheetAction(title: "Change", disabled: busy || !email.contains("@"), run: change)
            ) {
                Text(
                    "\(kid.name) keeps their watch history and joins with a code, like any added adult. "
                        + "Their PIN and ratings are removed."
                )
                .font(.system(size: 13)).foregroundStyle(Theme.secondary)
                LabeledField(label: "Email") {
                    TextField("", text: $email).keyboardType(.emailAddress).textContentType(.emailAddress)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityLabel("Email")
                }
                if let error { Text(error).font(.system(size: 13)).foregroundStyle(Theme.error) }
            }
        }
    }

    private func change() {
        busy = true
        Task {
            defer { busy = false }
            do {
                invite = try await model.makeAdult(kid, email: email.trimmingCharacters(in: .whitespaces))
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

/// Offers a member to one adult the server's admin connected the active adult with.
struct OfferSheet: View {
    @Environment(\.dismiss) private var dismiss
    let member: Account
    let model: HouseholdModel
    @State private var adults: [Account] = []
    @State private var chosen: Account.ID?
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        let name = member.name
        SheetPage(
            title: "Share \(name)",
            action: SheetAction(title: "Send offer", disabled: busy || chosen == nil, run: send)
        ) {
            Text(
                "Offer \(name) to an adult in another household. Once they accept, \(name) appears in Who's watching "
                    + "there with the same watch history, playlists and limits, and the adults there can change "
                    + "\(name)'s settings as you can."
            )
            .font(.system(size: 14)).foregroundStyle(Theme.secondary)
            Text("Offer to").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.secondary)
            VStack(spacing: 0) {
                ForEach(adults) { adult in
                    RadioRow(title: adult.name, selected: chosen == adult.id) {
                        chosen = adult.id
                    } leading: {
                        Avatar(account: adult, size: 36)
                    }
                }
            }
            Text("Only adults the server's admin has connected you with appear here.")
                .font(.system(size: 13)).foregroundStyle(Theme.secondary)
            if let error { Text(error).font(.system(size: 13)).foregroundStyle(Theme.error) }
        }
        .task {
            do {
                adults = try await model.connectedAdults()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func send() {
        guard let adult = adults.first(where: { $0.id == chosen }) else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                try await model.offer(member, to: adult)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

/// One choice of several, only one of which is picked.
struct RadioRow<Leading: View>: View {
    let title: String
    var detail: String?
    let selected: Bool
    let action: () -> Void
    @ViewBuilder var leading: Leading

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                leading
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.primary)
                    if let detail { Text(detail).font(.system(size: 13)).foregroundStyle(Theme.secondary) }
                }
                Spacer()
                Image(systemName: selected ? "largecircle.fill.circle" : "circle").font(.system(size: 22))
                    .foregroundStyle(selected ? Theme.amber : Theme.secondary)
            }
            .padding(.vertical, 10)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct AllowListView: View {
    let kid: Account
    let model: HouseholdModel
    @State private var allowed: [Item] = []
    @State private var query = ""
    @State private var found: [Item] = []
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Allowed titles").font(.system(size: 13, weight: .semibold))
            if allowed.isEmpty { Text("No titles yet.").font(.system(size: 12)).foregroundStyle(Theme.secondary) }
            ForEach(allowed, id: \.id) { item in
                row(item, "Remove") {
                    try await model.disallow(kid, item.id)
                    allowed.removeAll { $0.id == item.id }
                }
            }
            LabeledField(label: "Add a title") {
                TextField("", text: $query, prompt: Text("Find a title")).accessibilityLabel("Find a title to add")
            }
            ForEach(found, id: \.id) { item in
                row(item, "Add") {
                    try await model.allow(kid, item.id)
                    if !allowed.contains(where: { $0.id == item.id }) { allowed.append(item) }
                    query = ""
                }
            }
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(Theme.error) }
        }
        .task { await run { allowed = try await model.allowed(kid) } }
        .task(id: query) {
            let text = query.trimmingCharacters(in: .whitespaces)
            await run { found = text.isEmpty ? [] : try await model.findTitles(text) }
        }
    }

    private func row(_ item: Item, _ action: String, _ act: @escaping () async throws -> Void) -> some View {
        HStack {
            Text(Catalog.title(item)).font(.system(size: 15))
            Spacer()
            Button(action) {
                Task {
                    await run { try await act() }
                }
            }
            .buttonStyle(SecondaryButtonStyle(height: 32))
        }
    }

    private func run(_ body: () async throws -> Void) async {
        do {
            try await body()
            error = nil
        } catch {
            // A newer query cancels the search it replaces.
            if !Task.isCancelled { self.error = error.localizedDescription }
        }
    }
}
