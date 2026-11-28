import RabbitEarsKit
import SwiftUI

/// The active adult's requests received, friends and requests sent, in one list.
struct FriendsView: View {
    @Environment(\.dismiss) private var dismiss
    let model: FriendsModel
    @State private var adding = false
    @State private var removing: FriendCard?
    @State private var showingSent = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Friends").font(.system(size: 20, weight: .bold))
            if let notice = model.notice {
                Text(notice).font(.system(size: 13)).foregroundStyle(Theme.secondary)
            }
            List {
                if !model.received.isEmpty {
                    Section("Requests") {
                        ForEach(model.received) { request in
                            HStack(spacing: 12) {
                                FriendAvatar(name: request.name, rgb: request.rgb)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(request.name).font(.system(size: 13, weight: .semibold))
                                    Text(FriendsText.wants).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                                }
                                Spacer()
                                Button("Decline") { Task { await model.decline(request) } }
                                    .buttonStyle(SecondaryButtonStyle(height: 28))
                                Button("Accept") { Task { await model.accept(request) } }
                                    .buttonStyle(PrimaryButtonStyle(height: 28))
                            }
                            .padding(.vertical, 6)
                        }
                    }
                }
                Section("Friends") {
                    if model.friends.isEmpty {
                        Text(FriendsText.none).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                    }
                    ForEach(model.friends) { friend in
                        HStack(spacing: 12) {
                            FriendAvatar(name: friend.name, rgb: friend.rgb)
                            Text(friend.name).font(.system(size: 13, weight: .semibold))
                            Spacer()
                            More(name: friend.name) {
                                Button("Remove Friend", role: .destructive) { removing = friend }
                            }
                        }
                        .padding(.vertical, 6)
                        .contextMenu { Button("Remove Friend", role: .destructive) { removing = friend } }
                    }
                }
                if !model.sent.isEmpty {
                    Section {
                        DisclosureGroup("Sent (\(model.sent.count))", isExpanded: $showingSent) {
                            ForEach(model.sent) { sent in
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(sent.email).font(.system(size: 13, weight: .semibold))
                                        Text(sent.dates).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                                    }
                                    Spacer()
                                    More(name: sent.email) { Button("Withdraw") { withdraw(sent) } }
                                }
                                .padding(.vertical, 6)
                                .contextMenu { Button("Withdraw") { withdraw(sent) } }
                            }
                        }
                    }
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .frame(minHeight: 300)
            if let error = model.error {
                Text(error).font(.system(size: 13)).foregroundStyle(Color(hex: 0xFF6B6B))
            }
            HStack {
                Button("Add Friend…") { adding = true }.buttonStyle(SecondaryButtonStyle(height: 34))
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(PrimaryButtonStyle(height: 34))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 560)
        .background(Theme.card)
        .sheet(isPresented: $adding) { AddFriendView(model: model) }
        .confirmationDialog(
            removing.map { FriendsText.removeTitle($0.name) } ?? "",
            isPresented: .init(get: { removing != nil }, set: { if !$0 { removing = nil } }), presenting: removing
        ) { friend in
            Button("Remove", role: .destructive) { Task { await model.remove(friend) } }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text(FriendsText.removeMessage)
        }
    }

    private func withdraw(_ sent: SentFriendRequest) { Task { await model.withdraw(sent) } }
}

/// A row's trailing "…" menu.
private struct More<Items: View>: View {
    let name: String
    @ViewBuilder var items: Items

    var body: some View {
        Menu {
            items
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.button).buttonStyle(.plain).fixedSize()
        .accessibilityLabel("More for \(name)")
    }
}

/// A friend's initial on their color.
struct FriendAvatar: View {
    let name: String
    let rgb: UInt32

    var body: some View {
        Circle().fill(Color(hex: rgb)).frame(width: 36, height: 36)
            .overlay {
                Text(name.prefix(1).uppercased()).font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
            }
            .accessibilityHidden(true)
    }
}

/// One email field; every send the server takes closes it with the same line.
struct AddFriendView: View {
    @Environment(\.dismiss) private var dismiss
    let model: FriendsModel
    @State private var email = ""
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Friend").font(.system(size: 20, weight: .bold))
            Text(FriendsText.help).font(.system(size: 13)).foregroundStyle(Theme.secondary)
            LabeledField(label: "Email", error: error) {
                TextField("name@example.com", text: $email).textContentType(.emailAddress)
                    .autocorrectionDisabled().accessibilityLabel("Email").onSubmit(send)
            }
            HStack {
                Button("Cancel") { dismiss() }.buttonStyle(SecondaryButtonStyle(fullWidth: true, height: 40))
                    .keyboardShortcut(.cancelAction)
                Button(action: send) { Text("Send Request") }
                    .buttonStyle(PrimaryButtonStyle(fullWidth: true, height: 40))
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSend)
            }
        }
        .padding(28)
        .frame(width: 400)
        .background(Theme.card)
    }

    private var canSend: Bool { !busy && FriendsText.isEmail(email) }

    private func send() {
        guard canSend else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                try await model.send(email)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
