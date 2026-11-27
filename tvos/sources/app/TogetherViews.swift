import RabbitEarsAPI
import RabbitEarsKit
import SwiftUI

private struct StatePill: View {
    let text: String
    let color: Color
    var icon: String?

    var body: some View {
        HStack(spacing: 14) {
            if let icon {
                Image(systemName: icon).font(.system(size: 26, weight: .semibold))
            } else {
                Circle().fill(color).frame(width: 14, height: 14)
            }
            Text(text).font(.system(size: 30, weight: .bold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 28)
        .frame(minHeight: 76)
        .background(color.opacity(0.18), in: .rect(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }
}

struct TogetherButtons: View {
    let together: WatchTogetherModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 24) {
                if let waiting = together.waitingLabel(at: context.date) {
                    StatePill(text: waiting, color: Theme.amber)
                    Button("Cancel") { Task { await together.leave() } }.buttonStyle(TVButtonStyle())
                } else if let join = together.joinLabel(at: context.date) {
                    Button {
                        Task { await together.join() }
                    } label: {
                        Label(join, systemImage: "person.2")
                    }
                    .buttonStyle(TVButtonStyle())
                } else if together.inSync {
                    StatePill(
                        text: "In sync with \(together.partnerName ?? "them")", color: Theme.green, icon: "person.2")
                    Button("Leave") { Task { await together.leave() } }.buttonStyle(TVButtonStyle())
                } else {
                    Button {
                        Task { await together.open() }
                    } label: {
                        Label("Watch together", systemImage: "person.2")
                    }
                    .buttonStyle(TVButtonStyle())
                }
            }
        }
    }
}

struct TogetherNote: View {
    @Environment(AppModel.self) private var app
    let together: WatchTogetherModel
    let title: String

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            if let text = note(at: context.date) {
                Text(text).font(.system(size: 28)).foregroundStyle(Theme.synopsis).padding(.top, 24)
            }
        }
    }

    private func note(at date: Date) -> String? {
        if let error = together.error { return error }
        if together.waitingLabel(at: date) != nil {
            return
                "Someone else who opens \(title) and chooses Watch together in the next 5 minutes will play in sync "
                + "with you. Pause and play on either device apply to both."
        }
        if let join = together.joinLabel(at: date), let left = join.components(separatedBy: " · ").last,
            let host = together.invite?.members.first(where: { $0.role == .host })
        {
            return "\(host.name) wants to watch this together. Join in the next \(left) to play in sync."
        }
        guard together.inSync, let name = together.partnerName else { return nil }
        let other = together.current?.members.first { $0.accountId != app.activeProfile?.id }
        return "Pause and play on either device apply to both."
            + (other.map { " \(name) is watching on \(Self.device($0.platform))." } ?? "")
    }

    private static func device(_ platform: Components.Schemas.Platform) -> String {
        switch platform {
        case .web: "the web"
        case .macos: "a Mac"
        case .ios: "iPhone"
        case .tvos: "Apple TV"
        case .roku: "Roku"
        case .android: "Android"
        }
    }
}

struct SyncChip: View {
    let name: String

    var body: some View {
        Label("In sync with \(name)", systemImage: "person.2")
            .font(.system(size: 28, weight: .bold)).foregroundStyle(Theme.green)
            .padding(.horizontal, 22).padding(.vertical, 10)
            .background(Theme.green.opacity(0.18), in: .capsule)
    }
}

struct PausedNotice: View {
    let text: String
    let name: String

    var body: some View {
        HStack(spacing: 24) {
            Text(name.prefix(1).uppercased()).font(.system(size: 44, weight: .bold)).foregroundStyle(.white)
                .frame(width: 84, height: 84).background(Theme.placeholder(name.count), in: .circle)
            VStack(alignment: .leading, spacing: 2) {
                Text(text).font(.system(size: 42, weight: .bold))
                Text("Playing again resumes for both of you").font(.system(size: 30)).foregroundStyle(Theme.synopsis)
            }
        }
        .padding(24)
        .background(Theme.card.opacity(0.96), in: .rect(cornerRadius: 28))
        .shadow(color: .black.opacity(0.6), radius: 40, y: 20)
        .accessibilityElement(children: .combine)
    }
}
