import RabbitEarsAPI
import RabbitEarsKit
import SwiftUI

/// The icon button beside Play and Watched that opens a Watch together window.
struct TogetherButton: View {
    let model: WatchTogetherModel

    var body: some View {
        if model.current == nil && model.invite == nil {
            Button {
                Task { await model.open() }
            } label: {
                Image(systemName: "person.2").frame(width: 28)
            }
            .buttonStyle(SecondaryButtonStyle())
            .accessibilityLabel("Watch together")
        }
    }
}

/// Where a title's Watch together stands, under its buttons: Join with the
/// window left, Waiting with its countdown, or In sync with Leave.
struct TogetherNotice: View {
    let model: WatchTogetherModel
    let title: String

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let date = context.date
            if let join = model.joinLabel(at: date) {
                joinRow(join)
            } else if let waiting = model.waitingLabel(at: date) {
                waitingRow(waiting)
            } else if model.inSync, let partner = model.partnerName {
                syncRow(partner)
            }
        }
    }

    private func joinRow(_ label: String) -> some View {
        let left = label.components(separatedBy: " · ").last ?? ""
        let host = model.invite?.members.first { $0.role == .host }?.name ?? "Someone"
        return VStack(spacing: 8) {
            Button {
                Task { await model.join() }
            } label: {
                Label(label, systemImage: "person.2").frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.amber)
            .frame(minHeight: 44)
            .background(Theme.amber.opacity(0.12), in: .rect(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.amber, lineWidth: 1.5))
            note("\(host) wants to watch this together. Join in the next \(left) to play in sync.")
        }
    }

    private func waitingRow(_ label: String) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Circle().fill(Theme.amber).frame(width: 8, height: 8)
                Text(label.replacingOccurrences(of: "Waiting for someone to join", with: "Waiting"))
                    .font(.system(size: 15, weight: .semibold))
                Spacer(minLength: 0)
                Button {
                    Task { await model.leave() }
                } label: {
                    Image(systemName: "xmark").font(.system(size: 13, weight: .bold)).frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Cancel Watch together")
            }
            .foregroundStyle(Theme.amber).padding(.horizontal, 14).frame(minHeight: 44)
            .background(Theme.amber.opacity(0.16), in: .rect(cornerRadius: 8))
            note(
                "Someone else who opens \(title) and taps Watch together in the next 5 minutes will play in sync "
                    + "with you. Pause and play on either device apply to both."
            )
        }
    }

    private func syncRow(_ partner: String) -> some View {
        let device = model.current?.members.first { $0.name == partner }?.deviceName
        return VStack(spacing: 8) {
            SyncChip(partner: partner, leave: { Task { await model.leave() } }).frame(maxWidth: .infinity)
            note("Pause and play on either device apply to both." + (device.map { " \(partner) is on \($0)." } ?? ""))
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 13)).foregroundStyle(Theme.secondary).frame(
            maxWidth: .infinity, alignment: .leading)
    }
}

struct SyncChip: View {
    let partner: String
    let leave: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "person.2")
            Text("In sync with \(partner)").lineLimit(1)
            Button("Leave", action: leave)
                .buttonStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.primary)
                .padding(.horizontal, 10).frame(height: 26).background(.white.opacity(0.16), in: .capsule)
        }
        .font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.green)
        .padding(.horizontal, 14).frame(minHeight: 44)
        .background(Theme.green.opacity(0.16), in: .rect(cornerRadius: 8))
    }
}
