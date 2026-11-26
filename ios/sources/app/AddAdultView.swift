import RabbitEarsKit
import SwiftUI

/// The owner adds an adult, then hands over the code or link it returns.
struct AddAdultView: View {
    @Environment(AppModel.self) private var model
    @State private var name = ""
    @State private var email = ""
    @State private var invite: Invite?
    @State private var error: AppError?
    @State private var busy = false

    var body: some View {
        if let invite {
            SheetPage(title: "Invite \(name)", action: nil) { InviteDetails(invite: invite) }
        } else {
            SheetPage(
                title: "Add an adult", action: SheetAction(title: "Add", disabled: !canAdd, run: add)
            ) {
                Text("They get their own sign-in to this household and can look after the kids.")
                    .font(.system(size: 13)).foregroundStyle(Theme.secondary)
                LabeledField(label: "Name") {
                    TextField("", text: $name).textContentType(.name).accessibilityLabel("Name")
                }
                LabeledField(label: "Email") {
                    TextField("", text: $email).keyboardType(.emailAddress).textContentType(.emailAddress)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityLabel("Email")
                        .onSubmit(add)
                }
                if let error {
                    Text(error.localizedDescription).font(.system(size: 13)).foregroundStyle(Theme.secondary)
                }
            }
        }
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
    let invite: Invite

    var body: some View {
        Text("Give them this link or code. They pick a password when they open it.")
            .font(.system(size: 13)).foregroundStyle(Theme.secondary)
        Text(invite.code).font(.system(size: 28, weight: .bold, design: .monospaced)).textSelection(.enabled)
        Text(invite.url.absoluteString).font(.system(size: 13)).foregroundStyle(Theme.synopsis)
            .textSelection(.enabled).lineLimit(1).truncationMode(.middle)
        ShareLink(item: invite.url) { Label("Share link", systemImage: "square.and.arrow.up") }
            .buttonStyle(PrimaryButtonStyle(fullWidth: true))
    }
}
