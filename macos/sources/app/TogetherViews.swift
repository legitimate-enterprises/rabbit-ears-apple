import RabbitEarsAPI
import RabbitEarsKit
import SwiftUI

/// Keeps one Watch together model polling for as long as a details page is
/// on screen, wherever the player is.
struct TogetherPolling: ViewModifier {
    @Environment(AppModel.self) private var app
    let itemId: UID
    @Binding var together: WatchTogetherModel?
    /// Opens the player at the shared position when the other member starts it.
    let start: (Int64, WatchTogetherModel) -> Void

    func body(content: Content) -> some View {
        content.task(id: itemId) {
            guard let model = app.watchTogether(itemId: itemId) else { return }
            model.onStart = { [weak model] position in if let model { start(position, model) } }
            together = model
            await model.run()
            together = nil
        }
    }
}

extension View {
    func watchTogether(
        itemId: UID, model: Binding<WatchTogetherModel?>, start: @escaping (Int64, WatchTogetherModel) -> Void
    ) -> some View {
        modifier(TogetherPolling(itemId: itemId, together: model, start: start))
    }
}

struct TogetherControl: View {
    let together: WatchTogetherModel?

    var body: some View {
        if let together {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                if together.inSync {
                    chip("In sync with \(together.partnerName ?? "them")", tint: Theme.green, icon: "person.2") {
                        Button("Leave") { Task { await together.leave() } }
                            .buttonStyle(.plain).font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 8).padding(.vertical, 2).background(
                                .white.opacity(0.14), in: .capsule)
                    }
                } else if let label = together.waitingLabel(at: context.date) {
                    chip(label, tint: Theme.amber, icon: nil) {
                        Button {
                            Task { await together.leave() }
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .buttonStyle(.plain).accessibilityLabel("Stop waiting")
                    }
                } else if let label = together.joinLabel(at: context.date) {
                    Button {
                        Task { await together.join() }
                    } label: {
                        Label(label, systemImage: "person.2")
                    }
                    .buttonStyle(.plain).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.amber)
                    .padding(.horizontal, 14).frame(height: 32)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.amber, lineWidth: 1.5))
                } else {
                    Button {
                        Task { await together.open() }
                    } label: {
                        Label("Watch together", systemImage: "person.2")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
            }
            .fixedSize()
        }
    }

    private func chip<Trailing: View>(
        _ text: String, tint: Color, icon: String?, @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: 8) {
            if let icon { Image(systemName: icon) } else { Circle().fill(tint).frame(width: 8, height: 8) }
            Text(text)
            trailing().foregroundStyle(tint == Theme.green ? Theme.primary : tint)
        }
        .font(.system(size: 13, weight: .semibold)).foregroundStyle(tint)
        .padding(.horizontal, 14).frame(height: 32)
        .background(tint.opacity(0.16), in: .rect(cornerRadius: 8))
    }
}

struct TogetherHint: View {
    let together: WatchTogetherModel?
    let title: String

    var body: some View {
        if let together {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                if let text = text(together, at: context.date) {
                    Text(text).font(.system(size: 13)).foregroundStyle(Theme.secondary)
                        .frame(maxWidth: 560, alignment: .leading)
                }
            }
        }
    }

    private func text(_ together: WatchTogetherModel, at date: Date) -> String? {
        if together.inSync {
            let partner = together.current?.members.first { $0.name == together.partnerName }
            let device = partner.map { " is on \(Self.device($0.platform))" } ?? ""
            return "Pause and play on either device apply to both. \(together.partnerName ?? "They")\(device)."
        }
        if together.waitingLabel(at: date) != nil {
            return "Someone else who opens \(title) and taps Watch together in the next 5 minutes will play in sync "
                + "with you. Pause and play on either device apply to both."
        }
        if let label = together.joinLabel(at: date), let invite = together.invite,
            let host = invite.members.first(where: { $0.role == .host })
        {
            let time = label.split(separator: "·").last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            return "\(host.name) wants to watch this together. Join in the next \(time) to play in sync."
        }
        return nil
    }

    private static func device(_ platform: Components.Schemas.Platform) -> String {
        switch platform {
        case .web: "the web"
        case .macos: "a Mac"
        case .ios: "an iPhone or iPad"
        case .tvos: "Apple TV"
        case .roku: "a Roku"
        case .android: "Android"
        }
    }
}

struct TogetherPlayerChip: View {
    let together: WatchTogetherModel

    var body: some View {
        if together.inSync {
            HStack(spacing: 8) {
                Image(systemName: "person.2")
                Text("In sync with \(together.partnerName ?? "them")")
                Button("Leave") { Task { await together.leave() } }
                    .buttonStyle(.plain).foregroundStyle(Theme.primary)
                    .padding(.horizontal, 8).padding(.vertical, 2).background(.white.opacity(0.14), in: .capsule)
            }
            .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.green)
            .padding(.horizontal, 14).frame(height: 36)
            .background(Theme.green.opacity(0.16), in: .capsule)
        }
    }
}

struct TogetherNotice: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "pause.fill")
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 14).frame(height: 32)
            .background(.black.opacity(0.6), in: .capsule)
    }
}
