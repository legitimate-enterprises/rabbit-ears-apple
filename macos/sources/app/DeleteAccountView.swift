import RabbitEarsAPI
import RabbitEarsKit
import SwiftUI

/// Deletes the active adult's own account once they read what goes with it
/// and give their password; the app then returns to sign-in.
struct DeleteAccountView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var deletion: AccountDeletion?
    @State private var password = ""
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Delete your account?").font(.system(size: 20, weight: .bold))
            if let deletion {
                Text(deletion.summary).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                if deletion.allowed {
                    LabeledField(label: "Password") {
                        SecureField("", text: $password).textContentType(.password).accessibilityLabel("Password")
                            .onSubmit(delete)
                    }
                }
            } else if error == nil {
                ProgressView().controlSize(.small)
            }
            if let error { Text(error).font(.system(size: 13)).foregroundStyle(Theme.red) }
            HStack {
                if deletion?.allowed == false {
                    Button("OK") { dismiss() }.buttonStyle(PrimaryButtonStyle(fullWidth: true, height: 40))
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Cancel") { dismiss() }.buttonStyle(SecondaryButtonStyle(fullWidth: true, height: 40))
                        .keyboardShortcut(.cancelAction)
                    Button("Delete account", role: .destructive, action: delete)
                        .buttonStyle(DestructiveButtonStyle())
                        .disabled(busy || deletion == nil || password.isEmpty)
                }
            }
        }
        .padding(28)
        .frame(width: 400)
        .background(Theme.card)
        .task {
            do {
                deletion = try await model.accountDeletion()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func delete() {
        guard !busy, deletion?.allowed == true, !password.isEmpty else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                try await model.deleteAccount(password: password)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

private struct DestructiveButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 40)
            .background(Theme.red.opacity(configuration.isPressed ? 0.8 : 1), in: .rect(cornerRadius: 8))
            .contentShape(.rect)
    }
}
