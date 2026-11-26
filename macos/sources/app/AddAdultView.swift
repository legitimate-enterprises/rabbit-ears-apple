import AppKit
import RabbitEarsKit
import SwiftUI

/// The owner adds an adult, then hands over the code or link it returns.
struct AddAdultView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var email = ""
    @State private var invite: Invite?
    @State private var error: AppError?
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let invite {
                InviteDetails(name: name, invite: invite, done: { dismiss() })
            } else {
                Text("Add an adult").font(.system(size: 20, weight: .bold))
                Text("They get their own sign-in to this household and can look after the kids.")
                    .font(.system(size: 13)).foregroundStyle(Theme.secondary)
                LabeledField(label: "Name") { TextField("", text: $name).accessibilityLabel("Name") }
                LabeledField(label: "Email") {
                    TextField("", text: $email).textContentType(.emailAddress).accessibilityLabel("Email")
                        .onSubmit(add)
                }
                if let error {
                    Text(error.localizedDescription).font(.system(size: 13)).foregroundStyle(Theme.secondary)
                }
                HStack {
                    Button("Cancel") { dismiss() }.buttonStyle(SecondaryButtonStyle(fullWidth: true, height: 40))
                        .keyboardShortcut(.cancelAction)
                    Button(action: add) { Text("Add") }.buttonStyle(PrimaryButtonStyle(fullWidth: true, height: 40))
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canAdd)
                }
            }
        }
        .padding(28)
        .frame(width: 400)
        .background(Theme.card)
    }

    private var canAdd: Bool { !busy && !name.trimmingCharacters(in: .whitespaces).isEmpty && email.contains("@") }

    private func add() {
        guard canAdd else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                invite = try await model.addAdult(
                    name: name.trimmingCharacters(in: .whitespaces), email: email.trimmingCharacters(in: .whitespaces))
            } catch {
                self.error = error as? AppError ?? .server(error.localizedDescription)
            }
        }
    }
}

/// The code and link an added adult joins with; nothing is ever emailed.
struct InviteDetails: View {
    let name: String
    let invite: Invite
    let done: () -> Void

    var body: some View {
        Text("Invite \(name)").font(.system(size: 20, weight: .bold))
        Text("Give them this link or code. They pick a password when they open it.")
            .font(.system(size: 13)).foregroundStyle(Theme.secondary)
        HStack {
            Text(invite.url.absoluteString).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
            Spacer()
            Button("Copy link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(invite.url.absoluteString, forType: .string)
            }
        }
        Text(invite.code).font(.system(size: 22, weight: .bold, design: .monospaced)).textSelection(.enabled)
        Button("Done", action: done).buttonStyle(PrimaryButtonStyle(fullWidth: true, height: 40))
            .keyboardShortcut(.defaultAction)
    }
}
