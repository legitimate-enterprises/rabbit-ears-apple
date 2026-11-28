import RabbitEarsKit
import SwiftUI

/// The active adult's requests received, friends and requests sent, in one list.
struct FriendsScreen: View {
    let model: FriendsModel
    @State private var adding = false
    @State private var removing: FriendCard?
    @State private var showingSent = false

    var body: some View {
        List {
            if let notice = model.notice {
                Text(notice).font(.system(size: 13)).foregroundStyle(Theme.secondary).listRowBackground(Theme.raised)
            }
            if !model.received.isEmpty {
                Section("Requests") {
                    ForEach(model.received) { request in
                        HStack(spacing: 12) {
                            FriendAvatar(name: request.name, rgb: request.rgb)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(request.name).font(.system(size: 15, weight: .semibold))
                                Text(FriendsText.wants).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                            }
                            Spacer()
                            Button("Decline") { Task { await model.decline(request) } }
                                .buttonStyle(.bordered)
                            Button("Accept") { Task { await model.accept(request) } }
                                .buttonStyle(.borderedProminent).tint(Theme.amber)
                        }
                        .listRowBackground(Theme.raised)
                    }
                }
            }
            Section("Friends") {
                if model.friends.isEmpty {
                    Text(FriendsText.none).font(.system(size: 13)).foregroundStyle(Theme.secondary)
                        .listRowBackground(Theme.raised)
                }
                ForEach(model.friends) { friend in
                    HStack(spacing: 12) {
                        FriendAvatar(name: friend.name, rgb: friend.rgb)
                        Text(friend.name).font(.system(size: 15, weight: .semibold))
                    }
                    .listRowBackground(Theme.raised)
                    .swipeActions {
                        Button("Remove Friend", role: .destructive) { removing = friend }
                    }
                }
            }
            if !model.sent.isEmpty {
                Section {
                    DisclosureGroup("Sent (\(model.sent.count))", isExpanded: $showingSent) {
                        ForEach(model.sent) { sent in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(sent.email).font(.system(size: 15, weight: .semibold))
                                Text(sent.dates).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                            }
                            .swipeActions {
                                Button("Withdraw") { Task { await model.withdraw(sent) } }
                            }
                        }
                    }
                    .listRowBackground(Theme.raised)
                }
            }
            if let error = model.error {
                Text(error).font(.system(size: 13)).foregroundStyle(Theme.error).listRowBackground(Theme.raised)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.ground)
        .navigationTitle("Friends")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    adding = true
                } label: {
                    Image(systemName: "plus")
                }.accessibilityLabel("Add Friend")
            }
        }
        .sheet(isPresented: $adding) { AddFriendView(model: model) }
        .confirmationDialog(
            removing.map { FriendsText.removeTitle($0.name) } ?? "",
            isPresented: .init(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible,
            presenting: removing
        ) { friend in
            Button("Remove", role: .destructive) { Task { await model.remove(friend) } }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text(FriendsText.removeMessage)
        }
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
        SheetPage(title: "Add Friend", action: SheetAction(title: "Send Request", disabled: !canSend, run: send)) {
            Text(FriendsText.help).font(.system(size: 13)).foregroundStyle(Theme.secondary)
            LabeledField(label: "Email", error: error) {
                TextField("name@example.com", text: $email).keyboardType(.emailAddress)
                    .textContentType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityLabel("Email").onSubmit(send)
            }
        }
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
