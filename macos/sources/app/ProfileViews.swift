import RabbitEarsAPI
import RabbitEarsKit
import SwiftUI

struct ProfileMenu: View {
    @Environment(AppModel.self) private var model
    @State private var preferences = false

    var body: some View {
        Menu {
            Button("Switch profile") { Task { await model.switchProfile() } }
            if model.isAdult { Button("Preferences…") { preferences = true } }
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
        .accessibilityLabel("Profile: \(model.activeProfile?.name ?? "")")
    }
}

/// The active adult's preferences, saved as each is changed, with what
/// they manage of their household and account.
struct PreferencesSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var error: String?
    @State private var addingKid = false
    @State private var addingAdult = false
    @State private var managing = false
    @State private var changingPassword = false
    @State private var deleting = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Preferences").font(.system(size: 20, weight: .bold))
                    if let profile = model.activeProfile {
                        preferences(profile)
                        if let store = model.downloads {
                            Divider()
                            heading("Downloads")
                            DownloadsSection(store: store, profile: profile.id)
                        }
                        Divider()
                        heading("Household")
                        HStack {
                            if model.canManageHousehold { Button("Add a kid…") { addingKid = true } }
                            if model.isOwner { Button("Add an adult…") { addingAdult = true } }
                            Button("Manage household…") { managing = true }
                        }
                        .buttonStyle(SecondaryButtonStyle())
                        Divider()
                        heading("Account")
                        HStack {
                            Button("Password…") { changingPassword = true }
                            if profile.isAdmin, let endpoint = model.endpoint {
                                Button("Admin") { openURL(endpoint.resolve("/admin/")) }
                            }
                            Button("Delete account…", role: .destructive) { deleting = true }
                        }
                        .buttonStyle(SecondaryButtonStyle())
                    }
                }
                .padding(24)
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
            }
            .padding(EdgeInsets(top: 12, leading: 24, bottom: 20, trailing: 24))
        }
        // The main window is at least 600 points tall, so the sheet fits inside it and scrolls the rest.
        .frame(width: 460, height: 560)
        .background(Theme.card)
        .sheet(isPresented: $addingKid) { AddKidView(done: { addingKid = false }).frame(width: 580, height: 700) }
        .sheet(isPresented: $addingAdult) { AddAdultView() }
        .sheet(isPresented: $managing) { ManageHouseholdView() }
        .sheet(isPresented: $changingPassword) { ChangePasswordView() }
        .sheet(isPresented: $deleting) { DeleteAccountView() }
    }

    @ViewBuilder
    private func preferences(_ profile: Account) -> some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 6) {
            Text("Color").font(.system(size: 13)).foregroundStyle(Theme.secondary)
            ColorSwatches(
                selection: Binding(get: { profile.color }, set: { save(profile, color: $0) }))
        }
        Toggle(
            isOn: Binding(get: { profile.hideKidsContent == true }, set: { save(profile, hideKidsContent: $0) })
        ) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Hide kids' content").font(.system(size: 13, weight: .semibold))
                Text("Leave movies, shows and channels for kids out of your browsing.")
                    .font(.system(size: 12)).foregroundStyle(Theme.secondary)
            }
        }
        .toggleStyle(.switch)
        Toggle(isOn: Binding(get: { profile.autoplay ?? true }, set: { save(profile, autoplay: $0) })) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Autoplay").font(.system(size: 13, weight: .semibold))
                Text("Play what's up next 10 seconds after a title ends.")
                    .font(.system(size: 12)).foregroundStyle(Theme.secondary)
            }
        }
        .toggleStyle(.switch)
        Toggle(isOn: $model.profileMemory.remember) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Remember profile").font(.system(size: 13, weight: .semibold))
                Text("Open as the last profile used on this Mac, without Who's watching.")
                    .font(.system(size: 12)).foregroundStyle(Theme.secondary)
            }
        }
        .toggleStyle(.switch)
        if model.profileMemory.remember {
            Toggle(isOn: $model.profileMemory.skipPin) {
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
    }

    private func heading(_ title: String) -> some View {
        Text(title).font(.system(size: 13)).foregroundStyle(Theme.secondary)
    }

    private func save(
        _ profile: Account, color: String? = nil, hideKidsContent: Bool? = nil, autoplay: Bool? = nil
    ) {
        Task {
            do {
                try await model.savePreferences(
                    for: profile, color: color, hideKidsContent: hideKidsContent, autoplay: autoplay)
                error = nil
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
