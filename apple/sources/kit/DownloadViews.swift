import RabbitEarsAPI
import SwiftUI

/// A More menu's Download, as a choice of quality with the profile's
/// default first, or Remove download once the profile asked for it. Absent
/// without a downloads store, as on Apple TV.
public struct DownloadMenu: View {
    @Environment(AppModel.self) private var app
    @Environment(DownloadPrompt.self) private var prompt: DownloadPrompt?
    let target: DownloadTarget

    public init(_ target: DownloadTarget) { self.target = target }

    public var body: some View {
        if let store = app.downloads, let profile = app.activeProfile?.id {
            if store.request(target, profile: profile) != nil {
                Button("Remove download", systemImage: "xmark.circle") { store.remove(target, profile: profile) }
            } else {
                Menu("Download", systemImage: "arrow.down.circle") {
                    let preferred = store.settings(profile).quality
                    ForEach(DownloadQuality.choices(music: target.music, preferred: preferred), id: \.self) { quality in
                        Button(quality.label) { prompt?.ask(target, quality: quality, store: store, profile: profile) }
                    }
                }
            }
        }
    }
}

/// The status marks on an artwork's bottom edge at its trailing corner, in
/// one row whose rightmost is Downloaded, with Shared to its left and, for a
/// collection in a hand-made order, In your order leftmost.
public struct StatusBadges: View {
    let id: UID
    let scope: DownloadTarget.Scope
    let overBar: Bool
    let handOrdered: Bool
    let shared: Bool

    /// `overBar` lifts the row clear of a progress bar inset along the artwork's bottom.
    public init(
        id: UID, scope: DownloadTarget.Scope = .item, overBar: Bool = false, handOrdered: Bool = false,
        shared: Bool = false
    ) {
        self.id = id
        self.scope = scope
        self.overBar = overBar
        self.handOrdered = handOrdered
        self.shared = shared
    }

    public var body: some View {
        HStack(spacing: 4) {
            if handOrdered {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tint)
                    .frame(width: 17, height: 17)
                    .background(Circle().fill(.black.opacity(0.6)))
                    .accessibilityLabel("In your order")
            }
            if shared {
                Image(systemName: "person.2.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tint)
                    .frame(width: 17, height: 17)
                    .background(Circle().fill(.black.opacity(0.6)))
                    .accessibilityLabel("Shared")
            }
            DownloadBadge(id: id, scope: scope)
        }
        .padding(5)
        .padding(.bottom, overBar ? 6 : 0)
    }
}

/// The mark while a title, or a container's own request, is on this device for the active profile.
struct DownloadBadge: View {
    @Environment(AppModel.self) private var app
    let id: UID
    let scope: DownloadTarget.Scope

    var body: some View {
        if let store = app.downloads, let profile = app.activeProfile?.id,
            store.badged(id, scope: scope, profile: profile)
        {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.tint)
                .background(Circle().fill(.black.opacity(0.6)))
                .accessibilityLabel("Downloaded")
        }
    }
}

extension View {
    /// Hosts what Download asks: This is a lot for a big request, and why one could not start.
    public func downloadPrompt(_ prompt: DownloadPrompt, store: DownloadStore?) -> some View {
        self
            .alert(
                "This is a lot",
                isPresented: Binding(get: { prompt.asking != nil }, set: { if !$0 { prompt.asking = nil } }),
                presenting: prompt.asking
            ) { plan in
                Button("Download") { store?.keep(plan) }
                Button("Download, don't ask again") { store?.keep(plan, dontAskAgain: true) }
                Button("Cancel", role: .cancel) {}
            } message: { plan in
                Text(DownloadPrompt.message(plan))
            }
            .alert(
                "Can't download",
                isPresented: Binding(get: { prompt.error != nil }, set: { if !$0 { prompt.error = nil } })
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(prompt.error ?? "")
            }
            .environment(prompt)
    }
}
