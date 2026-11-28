import RabbitEarsAPI
import RabbitEarsKit
import SwiftUI

/// The active adult's own preferences, saved as each is changed, with what
/// they manage of their household and account; Remember profile and Skip
/// PIN are this iPhone's alone.
struct PreferencesView: View {
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
        NavigationStack {
            ScrollView {
                if let profile = model.activeProfile {
                    VStack(alignment: .leading, spacing: 18) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Color").font(.system(size: 13)).foregroundStyle(Theme.secondary)
                            ColorSwatches(selected: profile.color) { save(profile, color: $0) }
                        }
                        Toggle(
                            isOn: Binding(
                                get: { profile.hideKidsContent == true },
                                set: { save(profile, hideKidsContent: $0) })
                        ) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Hide kids\u{2019} content").font(.system(size: 15, weight: .semibold))
                                Text("Movies, shows and YouTube channels for kids stay out of your browsing.")
                                    .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                            }
                        }
                        .tint(Theme.amber)
                        .padding(12).background(Theme.raised, in: .rect(cornerRadius: 8))
                        Toggle(
                            isOn: Binding(
                                get: { profile.autoplay ?? true }, set: { save(profile, autoplay: $0) })
                        ) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Autoplay").font(.system(size: 15, weight: .semibold))
                                Text("Play what\u{2019}s up next 10 seconds after a title ends.")
                                    .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                            }
                        }
                        .tint(Theme.amber)
                        .padding(12).background(Theme.raised, in: .rect(cornerRadius: 8))
                        @Bindable var model = model
                        VStack(spacing: 12) {
                            Toggle(isOn: $model.profileMemory.remember) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Remember profile").font(.system(size: 15, weight: .semibold))
                                    Text("Open as the last profile used on this iPhone, without Who\u{2019}s watching.")
                                        .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                                }
                            }
                            if model.profileMemory.remember {
                                Divider()
                                Toggle(isOn: $model.profileMemory.skipPin) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Skip PIN").font(.system(size: 15, weight: .semibold))
                                        Text("Don\u{2019}t ask for that profile\u{2019}s PIN when Rabbit Ears opens.")
                                            .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                                    }
                                }
                            }
                        }
                        .tint(Theme.amber)
                        .padding(12).background(Theme.raised, in: .rect(cornerRadius: 8))
                        if let error { Text(error).font(.system(size: 13)).foregroundStyle(Theme.error) }
                        if let store = model.downloads {
                            heading("Downloads")
                            DownloadsSection(store: store, profile: profile.id)
                        }
                        heading("Household")
                        VStack(spacing: 0) {
                            if model.canManageHousehold {
                                row("Add a kid", icon: "plus") { addingKid = true }
                                Divider()
                            }
                            if model.isOwner {
                                row("Add an adult", icon: "plus") { addingAdult = true }
                                Divider()
                            }
                            row("Manage household", icon: "chevron.right") { managing = true }
                        }
                        .padding(.horizontal, 12).background(Theme.raised, in: .rect(cornerRadius: 8))
                        heading("Account")
                        VStack(spacing: 0) {
                            row("Password", icon: "chevron.right") { changingPassword = true }
                            if profile.isAdmin, let admin = model.endpoint?.resolve("/admin/") {
                                Divider()
                                row("Admin", icon: "arrow.up.forward.square") { openURL(admin) }
                            }
                        }
                        .padding(.horizontal, 12).background(Theme.raised, in: .rect(cornerRadius: 8))
                        row("Delete account", role: .destructive) { deleting = true }
                            .padding(.horizontal, 12).background(Theme.raised, in: .rect(cornerRadius: 8))
                    }
                    .padding(EdgeInsets(top: 8, leading: 16, bottom: 32, trailing: 16))
                }
            }
            .pulling {
                if let profile = model.activeProfile { await model.downloads?.sync(profile: profile.id) }
            }
            .background(Theme.ground)
            .navigationTitle("Preferences")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .foregroundStyle(Theme.primary)
        .sheet(isPresented: $addingKid) { AddKidView(done: { addingKid = false }) }
        .sheet(isPresented: $addingAdult) { AddAdultView() }
        .sheet(isPresented: $managing) { ManageHouseholdView() }
        .sheet(isPresented: $changingPassword) { ChangePasswordView() }
        .sheet(isPresented: $deleting) { DeleteAccountView() }
    }

    private func heading(_ title: String) -> some View {
        Text(title).font(.system(size: 13)).foregroundStyle(Theme.secondary).padding(.top, 10)
    }

    private func row(
        _ title: String, icon: String? = nil, role: ButtonRole? = nil, action: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: action) {
            HStack {
                Text(title).font(.system(size: 15, weight: .semibold))
                Spacer()
                if let icon {
                    Image(systemName: icon).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.secondary)
                }
            }
            .frame(minHeight: 48).contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(role == .destructive ? Theme.error : Theme.primary)
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

/// The server's profile colors to pick one from.
struct ColorSwatches: View {
    let selected: String?
    let pick: (String) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(ProfilePalette.colors.enumerated()), id: \.element) { index, hex in
                let chosen = selected?.uppercased() == hex
                Button {
                    pick(hex)
                } label: {
                    Circle().fill(Color(hex: ProfilePalette.rgb(hex) ?? 0)).frame(width: 32, height: 32)
                        .overlay(Circle().stroke(.white, lineWidth: chosen ? 3 : 0))
                        .frame(width: 36, height: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Color \(index + 1)")
                .accessibilityAddTraits(chosen ? .isSelected : [])
            }
        }
    }
}
