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
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let deletion {
                        Text(deletion.summary).font(.system(size: 15))
                        if deletion.allowed {
                            LabeledField(label: "Password") {
                                SecureField("", text: $password).textContentType(.password)
                                    .accessibilityLabel("Password").onSubmit(delete)
                            }
                            Button("Delete account", role: .destructive, action: delete)
                                .buttonStyle(.borderedProminent).tint(Theme.error)
                                .frame(maxWidth: .infinity)
                                .disabled(busy || password.isEmpty)
                        }
                    } else if error == nil {
                        ProgressView().frame(maxWidth: .infinity)
                    }
                    if let error { Text(error).font(.system(size: 13)).foregroundStyle(Theme.error) }
                }
                .padding(16)
            }
            .background(Theme.ground)
            .navigationTitle("Delete your account?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(deletion?.allowed == false ? "OK" : "Cancel") { dismiss() }
                }
            }
        }
        .foregroundStyle(Theme.primary)
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
