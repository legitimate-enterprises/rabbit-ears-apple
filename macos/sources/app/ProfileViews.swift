import RabbitEarsAPI
import RabbitEarsKit
import SwiftUI

struct ProfileMenu: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @State private var preferences = false
    @State private var managing = false
    @State private var changingPassword = false
    @State private var deleting = false

    var body: some View {
        let adult = model.isAdult
        Menu {
            Button("Switch profile") { Task { await model.switchProfile() } }
            if adult {
                Button("Preferences…") { preferences = true }
                Button("Manage household…") { managing = true }
            }
            if model.activeProfile?.isAdmin == true, let endpoint = model.endpoint {
                Button("Admin") { openURL(endpoint.resolve("/admin/")) }
            }
            if adult {
                Button("Password…") { changingPassword = true }
                Button("Delete account…", role: .destructive) { deleting = true }
            }
            Divider()
            Button("Sign out") { Task { await model.signOut() } }
        } label: {
            HStack(spacing: 8) {
                if let profile = model.activeProfile { Avatar(account: profile, size: 22) }
                Text(model.activeProfile?.name ?? "").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                Spacer()
            }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .sheet(isPresented: $preferences) { PreferencesSheet() }
        .sheet(isPresented: $changingPassword) { ChangePasswordView() }
        .sheet(isPresented: $managing) { ManageHouseholdView() }
        .sheet(isPresented: $deleting) { DeleteAccountView() }
        .accessibilityLabel("Profile: \(model.activeProfile?.name ?? "")")
    }
}

struct PreferencesSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var color: String?
    @State private var hideKidsContent = false
    @State private var autoplay = true
    @State private var memory = ProfileMemory(remember: false, skipPin: false)
    @State private var error: String?
    @State private var busy = false
    @State private var downloads = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Preferences").font(.system(size: 20, weight: .bold))
            VStack(alignment: .leading, spacing: 6) {
                Text("Color").font(.system(size: 13)).foregroundStyle(Theme.secondary)
                ColorSwatches(selection: $color)
            }
            Toggle(isOn: $hideKidsContent) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Hide kids' content").font(.system(size: 13, weight: .semibold))
                    Text("Leave movies, shows and channels for kids out of your browsing.")
                        .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                }
            }
            .toggleStyle(.switch)
            Toggle(isOn: $autoplay) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Autoplay").font(.system(size: 13, weight: .semibold))
                    Text("Play what's up next 10 seconds after a title ends.")
                        .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                }
            }
            .toggleStyle(.switch)
            Toggle(isOn: $memory.remember) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Remember profile").font(.system(size: 13, weight: .semibold))
                    Text("Open as the last profile used on this Mac, without Who's watching.")
                        .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                }
            }
            .toggleStyle(.switch)
            if memory.remember {
                Toggle(isOn: $memory.skipPin) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Skip PIN").font(.system(size: 13, weight: .semibold))
                        Text("Don't ask for that profile's PIN when Rabbit Ears opens.")
                            .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                    }
                }
                .toggleStyle(.switch)
                .padding(.leading, 20)
            }
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(Theme.red) }
            HStack {
                if let store = model.downloads {
                    Button("Downloads…") { downloads = true }.buttonStyle(SecondaryButtonStyle())
                        .sheet(isPresented: $downloads) {
                            if let profile = model.activeProfile { DownloadsSheet(store: store, profile: profile.id) }
                        }
                }
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(SecondaryButtonStyle()).keyboardShortcut(.cancelAction)
                Button("Save", action: save).buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                    .disabled(busy)
            }
        }
        .padding(24).frame(width: 420)
        .background(Theme.card)
        .onAppear {
            color = model.activeProfile?.color
            hideKidsContent = model.activeProfile?.hideKidsContent ?? false
            autoplay = model.activeProfile?.autoplay ?? true
            memory = model.profileMemory
        }
    }

    private func save() {
        guard let profile = model.activeProfile else { return }
        model.profileMemory.remember = memory.remember
        model.profileMemory.skipPin = memory.skipPin
        busy = true
        Task {
            defer { busy = false }
            do {
                try await model.savePreferences(
                    for: profile, color: color, hideKidsContent: hideKidsContent, autoplay: autoplay)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

struct ColorSwatches: View {
    @Binding var selection: String?

    var body: some View {
        HStack(spacing: 8) {
            ForEach(ProfilePalette.colors, id: \.self) { hex in
                let picked = selection?.uppercased() == hex
                Button {
                    selection = hex
                } label: {
                    Circle().fill(Color(hex: ProfilePalette.rgb(hex) ?? 0)).frame(width: 26, height: 26)
                        .overlay(Circle().stroke(Theme.primary, lineWidth: picked ? 2 : 0).padding(-3))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Color \(hex)")
                .accessibilityAddTraits(picked ? .isSelected : [])
            }
        }
        .padding(.vertical, 3)
    }
}
