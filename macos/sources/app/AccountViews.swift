import RabbitEarsAPI
import RabbitEarsKit
import SwiftUI

/// Sign in, or Accept an invite reached from it.
struct SignInFlow: View {
    @State private var accepting = false

    var body: some View {
        if accepting {
            AcceptView(back: { accepting = false })
        } else {
            SignInView(accept: { accepting = true })
        }
    }
}

struct SignInView: View {
    @Environment(AppModel.self) private var model
    let accept: () -> Void
    @State private var server = ""
    @State private var email = ""
    @State private var password = ""
    @State private var error: AppError?
    @State private var busy = false

    var body: some View {
        AccountCard {
            Text("Sign in to \(model.serverName(at: server))").font(.system(size: 22, weight: .bold)).lineLimit(1)
            LabeledField(label: "Server", error: serverError ? message : nil) {
                TextField("", text: $server, prompt: Text("media.example.com"))
                    .accessibilityLabel("Server")
            }
            LabeledField(label: "Email") {
                TextField("", text: $email).textContentType(.username).accessibilityLabel("Email")
            }
            LabeledField(label: "Password") {
                SecureField("", text: $password).textContentType(.password).accessibilityLabel("Password")
                    .onSubmit(submit)
            }
            if error != nil, !serverError {
                Text(message ?? "").font(.system(size: 13)).foregroundStyle(Theme.secondary)
            }
            Button(action: submit) {
                if busy { ProgressView().controlSize(.small) } else { Text("Sign in") }
            }
            .buttonStyle(PrimaryButtonStyle(fullWidth: true, height: 44))
            .keyboardShortcut(.defaultAction)
            .disabled(busy)
            Button("Have an invite code?", action: accept).buttonStyle(LinkButtonStyle())
        }
        .onAppear { if server.isEmpty { server = model.lastServer } }
    }

    private var message: String? { error?.localizedDescription }
    private var serverError: Bool { error.map { [.unreachable, .badServer, .insecureServer].contains($0) } ?? false }

    private func submit() {
        guard !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                try await model.signIn(server: server, email: email, password: password)
            } catch {
                self.error = error as? AppError ?? .server(error.localizedDescription)
            }
        }
    }
}

struct AcceptView: View {
    @Environment(AppModel.self) private var model
    let back: () -> Void
    @State private var server = ""
    @State private var code = ""
    @State private var preview: Components.Schemas.JoinPreview?
    @State private var name = ""
    @State private var password = ""
    @State private var confirmation = ""
    @State private var error: AppError?
    @State private var busy = false

    var body: some View {
        AccountCard(width: 440) {
            if error == .inviteInvalid {
                Text("This invite is no longer valid.").font(.system(size: 22, weight: .bold))
                Text("Ask the person who invited you for a new one.").foregroundStyle(Theme.secondary)
                Button("Sign in", action: back).buttonStyle(LinkButtonStyle())
            } else if let preview {
                form(preview)
            } else {
                codeStep
            }
        }
        .onAppear { if server.isEmpty { server = model.lastServer } }
    }

    private var codeStep: some View {
        Group {
            Text("Join with an invite").font(.system(size: 22, weight: .bold))
            LabeledField(label: "Server", error: fieldError) {
                TextField("", text: $server, prompt: Text("media.example.com")).accessibilityLabel("Server")
            }
            LabeledField(label: "Invite code or link") {
                TextField("", text: $code, prompt: Text("XXXX-XXXX")).accessibilityLabel("Invite code")
                    .onSubmit(lookUp)
                    .onChange(of: code) { _, text in
                        if let link = JoinCode.parseLink(text) {
                            server = link.server.baseURL.absoluteString
                            code = link.code
                        }
                    }
            }
            Button(action: lookUp) { Text("Continue") }
                .buttonStyle(PrimaryButtonStyle(fullWidth: true, height: 44))
                .keyboardShortcut(.defaultAction).disabled(busy)
            Button("Sign in instead", action: back).buttonStyle(LinkButtonStyle())
        }
    }

    private func form(_ preview: Components.Schemas.JoinPreview) -> some View {
        Group {
            VStack(alignment: .leading, spacing: 6) {
                Text("\(preview.invitedBy ?? "Someone") invited you to \(model.serverName(at: server))").font(
                    .system(size: 22, weight: .bold)
                ).lineLimit(1)
                Text("Create your account to join.").foregroundStyle(Theme.secondary)
            }
            LabeledField(label: "Server") { TextField("", text: .constant(server)).disabled(true).opacity(0.6) }
            LabeledField(label: "Name") { TextField("", text: $name).accessibilityLabel("Name") }
            LabeledField(label: "Password", error: checked.passwordError) {
                SecureField("", text: $password).textContentType(.newPassword).accessibilityLabel("Password")
            }
            LabeledField(label: "Confirm password", error: checked.confirmationError) {
                SecureField("", text: $confirmation).accessibilityLabel("Confirm password").onSubmit(create)
            }
            if let fieldError { Text(fieldError).font(.system(size: 13)).foregroundStyle(Theme.secondary) }
            Button(action: create) { Text("Create account") }
                .buttonStyle(PrimaryButtonStyle(fullWidth: true, height: 44))
                .keyboardShortcut(.defaultAction)
                .disabled(!canCreate)
            Text("This device will show your household. You can add kids after you sign in.")
                .font(.system(size: 13)).foregroundStyle(Theme.secondary)
        }
    }

    private var fieldError: String? { error.map { $0.localizedDescription } }
    private var checked: NewPassword { NewPassword(password, confirmation: confirmation) }
    private var canCreate: Bool { !busy && checked.isValid }

    private func lookUp() {
        guard !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                let found = try await model.joinPreview(server: server, code: code)
                name = found.name
                error = nil
                preview = found
            } catch {
                self.error = error as? AppError ?? .server(error.localizedDescription)
            }
        }
    }

    private func create() {
        guard canCreate else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                try await model.acceptJoin(server: server, code: code, name: name, password: password)
            } catch {
                self.error = error as? AppError ?? .server(error.localizedDescription)
            }
        }
    }
}

struct WhosWatchingView: View {
    @Environment(AppModel.self) private var model
    @State private var pinFor: Account?
    @State private var error: String?
    @FocusState private var focused: Account.ID?

    var body: some View {
        picker.sheet(item: $pinFor) { PinDialog(profile: $0) }
            .onAppear { pinFor = model.pinPrompt }
    }

    private var picker: some View {
        VStack(spacing: 40) {
            Text("Who's watching?").font(.system(size: 32, weight: .bold))
            HStack(alignment: .top, spacing: 40) {
                ForEach(model.profiles) { profile in
                    Button {
                        if profile.hasPin { pinFor = profile } else { choose(profile) }
                    } label: {
                        VStack(spacing: 12) {
                            Avatar(account: profile)
                                .overlay(alignment: .bottomTrailing) {
                                    if profile.hasPin {
                                        Circle().fill(Theme.ground).frame(width: 30, height: 30)
                                            .overlay(Image(systemName: "lock.fill").foregroundStyle(Theme.amber))
                                            .offset(x: 2, y: 2).accessibilityLabel("PIN required")
                                    }
                                }
                                .overlay(
                                    Circle().stroke(Theme.amber, lineWidth: focused == profile.id ? 3 : 0).padding(-3))
                            Text(profile.name).font(.system(size: 15, weight: .semibold))
                        }
                    }
                    .buttonStyle(.plain)
                    .focused($focused, equals: profile.id)
                    .accessibilityLabel(profile.hasPin ? "\(profile.name), PIN required" : profile.name)
                }
            }
            if let error { Text(error).font(.system(size: 13)).foregroundStyle(Color(hex: 0xFF6B6B)) }
            HStack(spacing: 6) {
                Text("This Mac is in \(model.householdName ?? "your")'s household.").foregroundStyle(Theme.secondary)
                Button("Not you? Sign in as someone else") { Task { await model.signOut() } }
                    .buttonStyle(LinkButtonStyle())
            }
            .font(.system(size: 13))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.ground)
    }

    /// The server has the last word: a PIN set since this list loaded asks for it.
    private func choose(_ profile: Account) {
        Task {
            do {
                try await model.choose(profile)
            } catch AppError.pinRequired {
                pinFor = profile
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

struct ChangePasswordView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var current = ""
    @State private var new = ""
    @State private var confirmation = ""
    @State private var error: AppError?
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Change password").font(.system(size: 20, weight: .bold))
            LabeledField(label: "Current password") {
                SecureField("", text: $current).textContentType(.password).accessibilityLabel("Current password")
            }
            LabeledField(label: "New password", error: checked.passwordError) {
                SecureField("", text: $new).textContentType(.newPassword).accessibilityLabel("New password")
            }
            LabeledField(label: "Confirm new password", error: checked.confirmationError) {
                SecureField("", text: $confirmation).accessibilityLabel("Confirm new password").onSubmit(save)
            }
            if let error { Text(error.localizedDescription).font(.system(size: 13)).foregroundStyle(Theme.secondary) }
            HStack {
                Button("Cancel") { dismiss() }.buttonStyle(SecondaryButtonStyle(fullWidth: true, height: 40))
                    .keyboardShortcut(.cancelAction)
                Button(action: save) { Text("Save") }.buttonStyle(PrimaryButtonStyle(fullWidth: true, height: 40))
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        .padding(28)
        .frame(width: 360)
        .background(Theme.card)
    }

    private var checked: NewPassword { NewPassword(new, confirmation: confirmation) }
    private var canSave: Bool { !busy && !current.isEmpty && checked.isValid }

    private func save() {
        guard canSave else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                try await model.changePassword(current: current, new: new)
                dismiss()
            } catch {
                self.error = error as? AppError ?? .server(error.localizedDescription)
            }
        }
    }
}
