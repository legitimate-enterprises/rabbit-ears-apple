import RabbitEarsKit
import SwiftUI

/// The PIN pad over Who's watching; four digits submit on their own.
struct PinDialog: View {
    @Environment(AppModel.self) private var model
    let profile: Account
    /// Unlocks the profile and stays on Who's watching instead of picking it.
    var unlockOnly = false
    let close: () -> Void
    @State private var entry = PinEntry()
    @State private var error: AppError?
    @State private var showHelp = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.62).ignoresSafeArea().onTapGesture(perform: close)
            VStack(spacing: 18) {
                Avatar(account: profile, size: 72)
                Text("Enter \(profile.name)'s PIN").font(.system(size: 20, weight: .bold)).accessibilityAddTraits(
                    .isHeader)
                HStack(spacing: 16) {
                    ForEach(0..<PinEntry.length, id: \.self) { index in
                        Circle().fill(index < entry.digits.count ? Theme.amber : .white.opacity(0.2))
                            .frame(width: 14, height: 14)
                    }
                }
                .accessibilityElement().accessibilityLabel(entry.accessibilityLabel)
                if let error {
                    Text(error.localizedDescription).font(.system(size: 13)).foregroundStyle(Theme.secondary)
                }
                keypad.padding(.top, 8)
                Button(showHelp ? "An adult in your household can reset it." : "Forgot PIN?") { showHelp = true }
                    .buttonStyle(LinkButtonStyle()).font(.system(size: 13))
                Button("Cancel", action: close).buttonStyle(SecondaryButtonStyle(fullWidth: true, height: 40))
            }
            .multilineTextAlignment(.center)
            .padding(24)
            .frame(maxWidth: 342)
            .background(Theme.card, in: .rect(cornerRadius: 16))
            .shadow(color: .black.opacity(0.6), radius: 30, y: 20)
            .padding(24)
        }
        .accessibilityAddTraits(.isModal)
    }

    private var keypad: some View {
        Grid(horizontalSpacing: 20, verticalSpacing: 14) {
            ForEach([["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"]], id: \.self) { row in
                GridRow { ForEach(row, id: \.self) { key($0) } }
            }
            GridRow {
                Color.clear.frame(width: 72, height: 64)
                key("0")
                Button {
                    entry.deleteBackward()
                } label: {
                    Image(systemName: "delete.left").font(.system(size: 22)).frame(width: 72, height: 64)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Delete")
            }
        }
        .disabled(error == .pinLocked)
    }

    private func key(_ digit: String) -> some View {
        Button {
            if entry.type(Character(digit)) { submit() }
        } label: {
            Text(digit).font(.system(size: 26, weight: .medium)).frame(width: 72, height: 64)
                .background(.white.opacity(0.12), in: .capsule)
        }
        .buttonStyle(.plain)
    }

    private func submit() {
        let pin = entry.digits
        Task {
            do {
                if unlockOnly {
                    try await model.unlock(profile, pin: pin)
                } else {
                    try await model.choose(profile, pin: pin)
                }
                close()
            } catch {
                self.error = error as? AppError ?? .server(error.localizedDescription)
                entry.clear()
            }
        }
    }
}
