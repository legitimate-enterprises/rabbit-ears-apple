import RabbitEarsKit
import SwiftUI

/// The owner's Share sheet: households, then profiles, each change applying at once.
struct PlaylistShareSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State var model: PlaylistSharesModel
    let name: String

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Share").font(.system(size: 17, weight: .bold))
                Text(name).font(.system(size: 12)).foregroundStyle(Theme.secondary)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Households").font(.system(size: 13, weight: .bold))
                ForEach(model.households, id: \.id) { household in
                    ShareRow(
                        title: household.name, subtitle: household.profilesLabel, choices: PlaylistShareAccess.allCases,
                        access: model.access(household), set: { await model.set(household, to: $0) },
                        icon: {
                            Circle().fill(Theme.raised).frame(width: 36, height: 36)
                                .overlay { Image(systemName: "house").foregroundStyle(Theme.primary) }
                        }
                    )
                }
                Text("Everyone in the household can see it.").font(.system(size: 12)).foregroundStyle(Theme.secondary)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Profiles").font(.system(size: 13, weight: .bold))
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
                                    Text(profile.name.prefix(1).uppercased()).font(.system(size: 15, weight: .bold))
                                        .foregroundStyle(.white)
                                }
                                .accessibilityHidden(true)
                        }
                    )
                }
            }
            if let error = model.error { Text(error).foregroundStyle(.red).font(.system(size: 12)) }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(SecondaryButtonStyle())
            }
        }
        .padding(24).frame(width: 460)
        .background(Theme.card)
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
        HStack(spacing: 12) {
            icon
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                if let subtitle { Text(subtitle).font(.system(size: 12)).foregroundStyle(Theme.secondary) }
            }
            Spacer()
            let selection = Binding(get: { access }, set: { new in Task { await set(new) } })
            Picker("Access for \(title)", selection: selection) {
                Text(PlaylistShareAccess?.none.label).tag(PlaylistShareAccess?.none)
                ForEach(choices, id: \.self) { Text($0.label).tag(Optional($0)) }
            }
            .labelsHidden().fixedSize()
        }
    }
}
