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
            AddKidView(
                editing: kid, household: model, save: { try await model.saveKid(kid, $0) }, done: { dismiss() }
            )
            .frame(width: 580, height: 700)
        case .pin(let member): PinSheet(member: member, model: model)
        case .toAdult(let kid): ChangeToAdultSheet(kid: kid, model: model)
        case .share(let member): OfferSheet(member: member, model: model)
        case .invite(let name, let invite):
            SheetCard { InviteDetails(name: name, invite: invite, done: { dismiss() }) }
        }
    }
}

struct SheetCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) { content }
            .padding(28)
            .frame(width: 400)
            .background(Theme.card)
    }
}

struct SheetButtons: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let disabled: Bool
    let action: () -> Void

    var body: some View {
        HStack {
            Button("Cancel") { dismiss() }.buttonStyle(SecondaryButtonStyle(fullWidth: true, height: 40))
                .keyboardShortcut(.cancelAction)
            Button(title, action: action).buttonStyle(PrimaryButtonStyle(fullWidth: true, height: 40))
                .keyboardShortcut(.defaultAction).disabled(disabled)
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
        SheetCard {
            Text(member.hasPin ? "Change \(member.name)'s PIN" : "Set a PIN for \(member.name)")
                .font(.system(size: 20, weight: .bold))
            Text("Four digits, asked for when switching to \(member.name) on any device.")
                .font(.system(size: 13)).foregroundStyle(Theme.secondary)
            LabeledField(label: "PIN") { SecureField("", text: $pin).accessibilityLabel("PIN") }
            LabeledField(label: "Confirm PIN", error: mismatch ? "PINs don't match." : nil) {
                SecureField("", text: $confirmation).accessibilityLabel("Confirm PIN").onSubmit { save(pin) }
            }
            if let error { Text(error).font(.system(size: 13)).foregroundStyle(Color(hex: 0xFF6B6B)) }
            if member.hasPin {
                Button("Remove PIN") { save(nil) }.buttonStyle(LinkButtonStyle())
            }
            SheetButtons(title: "Save", disabled: !valid) { save(pin) }
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
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SheetCard {
            if let invite {
                InviteDetails(name: kid.name, invite: invite, done: { dismiss() })
            } else {
                Text("Change \(kid.name) to an adult").font(.system(size: 20, weight: .bold))
                Text(
                    "They keep their watch history and join with a code, like any added adult. "
                        + "Their PIN and ratings are removed."
                )
                .font(.system(size: 13)).foregroundStyle(Theme.secondary)
                LabeledField(label: "Email") {
                    TextField("", text: $email).textContentType(.emailAddress).accessibilityLabel("Email")
                }
                if let error { Text(error).font(.system(size: 13)).foregroundStyle(Color(hex: 0xFF6B6B)) }
                SheetButtons(title: "Change to adult", disabled: busy || !email.contains("@")) {
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
        SheetCard {
            Text("Share \(name)").font(.system(size: 20, weight: .bold))
            Text(
                "Offer \(name) to an adult in another household. Once they accept, \(name) appears in Who's watching "
                    + "there with the same watch history, playlists and limits, and the adults there can change "
                    + "\(name)'s settings as you can."
            )
            .font(.system(size: 13)).foregroundStyle(Theme.secondary)
            Picker("Offer to", selection: $chosen) {
                ForEach(adults) { Text($0.name).tag(Optional($0.id)) }
            }
            .pickerStyle(.radioGroup)
            Text("Only adults the server's admin has connected you with appear here.")
                .font(.system(size: 12)).foregroundStyle(Theme.secondary)
            if let error { Text(error).font(.system(size: 13)).foregroundStyle(Color(hex: 0xFF6B6B)) }
            SheetButtons(title: "Send offer", disabled: busy || chosen == nil) { send() }
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
            TextField("Find a title", text: $query).accessibilityLabel("Find a title to add")
            ForEach(found, id: \.id) { item in
                row(item, "Add") {
                    try await model.allow(kid, item.id)
                    if !allowed.contains(where: { $0.id == item.id }) { allowed.append(item) }
                    query = ""
                }
            }
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(Color(hex: 0xFF6B6B)) }
        }
        .task { await run { allowed = try await model.allowed(kid) } }
        .task(id: query) {
            let text = query.trimmingCharacters(in: .whitespaces)
            await run { found = text.isEmpty ? [] : try await model.findTitles(text) }
        }
    }

    private func row(_ item: Item, _ action: String, _ act: @escaping () async throws -> Void) -> some View {
        HStack {
            Text(Catalog.title(item)).font(.system(size: 13))
            Spacer()
            Button(action) {
                Task {
                    await run { try await act() }
                }
            }
            .buttonStyle(SecondaryButtonStyle(height: 28))
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
