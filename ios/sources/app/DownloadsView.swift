import RabbitEarsAPI
import RabbitEarsKit
import SwiftUI

/// Preferences' Downloads: the profile's downloads. Wi-Fi only and the
/// storage allowance are the iPhone's, for every profile.
struct DownloadsView: View {
    @Environment(AppModel.self) private var model
    let store: DownloadStore
    let profile: UID

    static let allowances: [Int64] = [5, 10, 20, 50, 100, 200, 500].map { $0 << 30 }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                settings
                storage
                list
            }
            .padding(EdgeInsets(top: 8, leading: 16, bottom: 32, trailing: 16))
        }
        .pulling { await store.sync(profile: profile) }
        .background(Theme.ground)
        .navigationTitle("Downloads")
        .navigationBarTitleDisplayMode(.inline)
        .tint(Theme.amber)
    }

    private var preferences: Binding<DownloadSettings> {
        Binding(get: { store.settings(profile) }, set: { store.setSettings($0, for: profile) })
    }

    private var settings: some View {
        VStack(spacing: 12) {
            Toggle(isOn: preferences.preferLocal) {
                SettingText(
                    title: "Prefer downloads",
                    detail: "Play what\u{2019}s on this iPhone from here, even with the server in reach.")
            }
            Divider()
            Picker(selection: preferences.quality) {
                ForEach(DownloadQuality.choices(music: false), id: \.self) { Text($0.label).tag($0) }
            } label: {
                SettingText(title: "Quality", detail: "What Download picks first. Music is Original or AAC 256.")
            }
            Divider()
            Toggle(isOn: preferences.confirmBig) {
                SettingText(title: "Ask before big downloads", detail: "Over 50 titles or a fifth of the space.")
            }
            Divider()
            @Bindable var store = store
            Toggle(isOn: $store.wifiOnly) {
                SettingText(title: "Wi-Fi only", detail: "Wait for Wi-Fi to download. Low Data Mode always waits.")
            }
        }
        .padding(12).background(Theme.raised, in: .rect(cornerRadius: 8))
    }

    private var storage: some View {
        VStack(spacing: 12) {
            @Bindable var store = store
            Picker(selection: $store.allowanceBytes) {
                ForEach(Self.allowances, id: \.self) { Text(Format.bytes($0)).tag($0) }
            } label: {
                SettingText(
                    title: "Space", detail: "\(Format.bytes(store.usedBytes)) used. Beyond it, downloads wait.")
            }
            let libraries = store.libraries.filter { $0.kind != .music }
            ForEach(libraries, id: \.id) { library in
                Divider()
                Toggle(
                    isOn: Binding(
                        get: { store.settings(profile).keeps(library) },
                        set: { preferences.wrappedValue.keep[library.id] = $0 })
                ) {
                    SettingText(title: "Keep watched: \(library.name)", detail: "Off removes a title once watched.")
                }
            }
        }
        .padding(12).background(Theme.raised, in: .rect(cornerRadius: 8))
    }

    @ViewBuilder private var list: some View {
        let requests = store.requests(for: profile)
        if requests.isEmpty {
            Text("Nothing downloaded. Download is in a title\u{2019}s More menu.")
                .font(.system(size: 13)).foregroundStyle(Theme.secondary)
        } else {
            VStack(spacing: 0) {
                ForEach(requests) { request in
                    if request.id != requests.first?.id { Divider() }
                    row(request)
                }
            }
            .padding(.horizontal, 12).background(Theme.raised, in: .rect(cornerRadius: 8))
        }
    }

    private func row(_ request: DownloadRequest) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(request.target.name).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                Text("\(Format.bytes(store.sizeBytes(request))) · \(request.quality.label) · \(store.state(request))")
                    .font(.system(size: 12)).foregroundStyle(Theme.secondary).lineLimit(2)
            }
            Spacer(minLength: 0)
            if store.failed(request) {
                Button("Retry", systemImage: "arrow.clockwise") { store.retry(request) }.labelStyle(.iconOnly)
                    .frame(width: 44, height: 44)
            }
            Button("Remove \(request.target.name)", systemImage: "trash", role: .destructive) {
                store.remove(request.target, profile: profile)
            }
            .labelStyle(.iconOnly).frame(width: 44, height: 44)
        }
        .padding(.vertical, 6)
    }
}

private struct SettingText: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 15, weight: .semibold))
            Text(detail).font(.system(size: 12)).foregroundStyle(Theme.secondary)
        }
    }
}
