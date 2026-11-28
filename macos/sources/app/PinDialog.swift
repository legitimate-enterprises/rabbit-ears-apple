import RabbitEarsKit
import SwiftUI

/// A full entry submits on its own.
struct PinDialog: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let profile: Account
    @State private var entry = PinEntry()
    @State private var error: AppError?
    @State private var showHelp = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 18) {
            Avatar(account: profile, size: 72)
            Text("Enter \(profile.name)'s PIN").font(.system(size: 20, weight: .bold))
            HStack(spacing: 16) {
                ForEach(0..<PinEntry.length, id: \.self) { index in
                    Circle().fill(index < entry.digits.count ? Theme.amber : .white.opacity(0.2))
                        .frame(width: 14, height: 14)
                }
            }
            .accessibilityElement().accessibilityLabel(entry.accessibilityLabel)
            if let error { Text(error.localizedDescription).font(.system(size: 13)).foregroundStyle(Theme.secondary) }
            Button(showHelp ? "An adult in your household can reset it." : "Forgot PIN?") { showHelp = true }
                .buttonStyle(LinkButtonStyle())
            Button("Cancel") { dismiss() }.buttonStyle(SecondaryButtonStyle(fullWidth: true, height: 40))
                .keyboardShortcut(.cancelAction)
        }
        .multilineTextAlignment(.center)
        .padding(28)
        .frame(width: 340)
        .background(Theme.card)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true }
        .onKeyPress(.delete) {
            entry.deleteBackward()
            return .handled
        }
        .onKeyPress(characters: .decimalDigits) { press in
            guard error != .pinLocked, let digit = press.characters.first else { return .ignored }
            if entry.type(digit) { submit() }
            return .handled
        }
    }

    private func submit() {
        let pin = entry.digits
        Task {
            do {
                try await model.choose(profile, pin: pin)
                dismiss()
            } catch {
                self.error = error as? AppError ?? .server(error.localizedDescription)
                entry.clear()
            }
        }
    }
}
