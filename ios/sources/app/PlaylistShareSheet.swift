import RabbitEarsKit
import SwiftUI

/// The owner's Share sheet: households, then profiles, each change applying at once.
struct PlaylistShareSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model: PlaylistSharesModel
    private let name: String

    init(playlists: PlaylistsModel, playlist: Playlist) {
        _model = State(initialValue: playlists.shares(of: playlist.id))
        name = playlist.name
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(model.households, id: \.id) { household in
                        ShareRow(
                            title: household.name, subtitle: household.profilesLabel,
                            choices: PlaylistShareAccess.allCases, access: model.access(household),
                            set: { await model.set(household, to: $0) },
                            icon: {
                                Circle().fill(Theme.raised).frame(width: 36, height: 36)
                                    .overlay { Image(systemName: "house").foregroundStyle(Theme.primary) }
                            }
                        )
                    }
                } header: {
                    Text("Households")
                } footer: {
                    Text("Everyone in the household can see it.")
                }
                Section("Profiles") {
                    if model.profiles.isEmpty {
                        Text("No one else to share with yet.").foregroundStyle(Theme.secondary)
                    }
                    ForEach(model.profiles) { profile in
                        ShareRow(
                            title: profile.name, subtitle: profile.subtitle, choices: profile.choices,
                            access: model.access(profile), set: { await model.set(profile, to: $0) },
                            icon: {
                                Circle().fill(profile.rgb.map { Color(hex: $0) } ?? Theme.raised)
                                    .frame(width: 36, height: 36)
                                    .overlay {
                                        Text(profile.name.prefix(1).uppercased())
                                            .font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                                    }
                                    .accessibilityHidden(true)
                            }
                        )
                    }
                }
                if let error = model.error {
                    Text(error).font(.system(size: 13)).foregroundStyle(Theme.error)
                }
            }
            .navigationTitle("Share").navigationSubtitle(name).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .task { await model.load() }
    }
}

/// A household or profile with its access menu.
private struct ShareRow<Icon: View>: View {
    let title: String
    let subtitle: String?
    let choices: [PlaylistShareAccess]
    let access: PlaylistShareAccess?
    let set: (PlaylistShareAccess?) async -> Void
    @ViewBuilder let icon: Icon

    var body: some View {
        Picker(selection: Binding(get: { access }, set: { new in Task { await set(new) } })) {
            Text(PlaylistShareAccess?.none.label).tag(PlaylistShareAccess?.none)
            ForEach(choices, id: \.self) { Text($0.label).tag(Optional($0)) }
        } label: {
            HStack(spacing: 12) {
                icon
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    if let subtitle { Text(subtitle).font(.system(size: 13)).foregroundStyle(Theme.secondary) }
                }
            }
        }
    }
}
