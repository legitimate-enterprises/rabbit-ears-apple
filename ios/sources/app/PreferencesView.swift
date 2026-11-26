import RabbitEarsAPI
import RabbitEarsKit
import SwiftUI

/// The active adult's own preferences, saved as each is changed; Remember
/// profile and Skip PIN are this iPhone's alone.
struct PreferencesView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?

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
                        if let store = model.downloads {
                            NavigationLink {
                                DownloadsView(store: store, profile: profile.id)
                            } label: {
                                HStack {
                                    Text("Downloads").font(.system(size: 15, weight: .semibold))
                                    Spacer()
                                    Text(Format.bytes(store.usedBytes)).font(.system(size: 13))
                                        .foregroundStyle(Theme.secondary)
                                    Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(Theme.secondary)
                                }
                                .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            .padding(12).background(Theme.raised, in: .rect(cornerRadius: 8))
                        }
                        if let error { Text(error).font(.system(size: 13)).foregroundStyle(Theme.error) }
                    }
                    .padding(EdgeInsets(top: 8, leading: 16, bottom: 32, trailing: 16))
                }
            }
            .background(Theme.ground)
            .navigationTitle("Preferences")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .foregroundStyle(Theme.primary)
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
