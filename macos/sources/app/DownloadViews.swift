import RabbitEarsAPI
import RabbitEarsKit
import SwiftUI

struct DownloadButton: View {
    let target: DownloadTarget

    var body: some View {
        DownloadMenu(target)
            .menuStyle(.button).buttonStyle(SecondaryButtonStyle()).fixedSize()
    }
}

/// Wi-Fi only and the storage allowance are the Mac's, for every profile.
/// Each change takes effect as it is made.
struct DownloadsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let store: DownloadStore
    let profile: UID

    static let allowances: [Int64] = [5, 10, 20, 50, 100, 200, 500].map { $0 << 30 }

    var body: some View {
        @Bindable var store = store
        VStack(alignment: .leading, spacing: 14) {
            Text("Downloads").font(.system(size: 20, weight: .bold))
            SettingRow(
                title: "Prefer downloads",
                detail: "Play what's on this Mac from here, even with the server in reach."
            ) { Toggle("Prefer downloads", isOn: preferences.preferLocal).toggleStyle(.switch) }
            SettingRow(title: "Ask before big downloads", detail: "Over 50 titles or a fifth of the space.") {
                Toggle("Ask before big downloads", isOn: preferences.confirmBig).toggleStyle(.switch)
            }
            SettingRow(
                title: "Wi-Fi only",
                detail: "Wait for a network that isn't a hotspot to download. Low Data Mode always waits."
            ) { Toggle("Wi-Fi only", isOn: $store.wifiOnly).toggleStyle(.switch) }
            SettingRow(title: "Quality") {
                Picker("Quality", selection: preferences.quality) {
                    ForEach(DownloadQuality.choices(music: false), id: \.self) { Text($0.label).tag($0) }
                }
            }
            SettingRow(title: "Space") {
                Picker("Space", selection: $store.allowanceBytes) {
                    ForEach(Self.allowances, id: \.self) { Text(Format.bytes($0)).tag($0) }
                }
            }
            Text(
                "\(Format.bytes(store.usedBytes)) used. Beyond the space, downloads wait. Music is Original or AAC 256."
            )
            .lineLimit(2).font(.system(size: 12)).foregroundStyle(Theme.secondary)
            ForEach(store.libraries.filter { $0.kind != .music }, id: \.id) { library in
                Toggle(
                    "Keep watched: \(library.name)",
                    isOn: Binding(
                        get: { store.settings(profile).keeps(library) },
                        set: { preferences.wrappedValue.keep[library.id] = $0 }))
            }
            list
            HStack {
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(width: 460)
        .background(Theme.card)
    }

    private var preferences: Binding<DownloadSettings> {
        Binding(get: { store.settings(profile) }, set: { store.setSettings($0, for: profile) })
    }

    @ViewBuilder private var list: some View {
        let requests = store.requests(for: profile)
        if requests.isEmpty {
            Text("Nothing downloaded. Download is beside a title's Play or in its More menu.")
                .font(.system(size: 12)).foregroundStyle(Theme.secondary)
        } else {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(requests) { request in
                        if request.id != requests.first?.id { Divider() }
                        row(request)
                    }
                }
            }
            .frame(maxHeight: 240)
        }
    }

    private func row(_ request: DownloadRequest) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(request.target.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text("\(Format.bytes(store.sizeBytes(request))) · \(request.quality.label) · \(store.state(request))")
                    .font(.system(size: 12)).foregroundStyle(Theme.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if store.failed(request) {
                Button("Retry") { store.retry(request) }.buttonStyle(SecondaryButtonStyle())
            }
            Button("Remove") { store.remove(request.target, profile: profile) }.buttonStyle(SecondaryButtonStyle())
                .accessibilityLabel("Remove \(request.target.name)")
        }
        .padding(.vertical, 6)
    }
}

/// The label and caption wrap in the leading column; every control sits in the trailing one.
private struct SettingRow<Control: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder let control: Control

    var body: some View {
        // Outside a Form, LabeledContent hugs its label, so the label column takes the slack instead.
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                if let detail {
                    Text(detail).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            control.labelsHidden().fixedSize()
        }
    }
}
