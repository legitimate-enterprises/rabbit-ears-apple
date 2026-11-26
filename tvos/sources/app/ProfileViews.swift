import RabbitEarsAPI
import RabbitEarsKit
import SwiftUI

struct WhoView: View {
    @Environment(AppModel.self) private var model
    @State private var pinFor: Account?
    @State private var error: String?

    var body: some View {
        AccountPage(name: model.serverName) {
            VStack(spacing: 0) {
                Text("Who's watching?").font(.system(size: 72, weight: .bold)).padding(.top, 140)
                HStack(alignment: .top, spacing: 88) {
                    ForEach(model.profiles) { profile in
                        Button {
                            if profile.hasPin { pinFor = profile } else { choose(profile) }
                        } label: {
                            ProfileFace(profile: profile)
                        }
                        .buttonStyle(ProfileButtonStyle())
                        .accessibilityLabel(profile.hasPin ? "\(profile.name), PIN required" : profile.name)
                    }
                }
                .padding(.top, 70)
                .focusSection()
                if let error { Text(error).font(.system(size: 28)).foregroundStyle(Theme.amber).padding(.top, 30) }
                HStack(spacing: 28) {
                    Text("This Apple TV is in \(model.householdName ?? "your")'s household.")
                        .font(.system(size: 30)).foregroundStyle(Theme.secondary)
                    Button("Sign in as someone else") { Task { await model.signOut() } }
                        .buttonStyle(TVButtonStyle())
                }
                .padding(.top, 70)
                .focusSection()
            }
            .frame(maxWidth: .infinity)
        }
        // The pad holds focus while it is up.
        .disabled(pinFor != nil)
        .overlay { if let profile = pinFor { PinPad(profile: profile) { pinFor = nil } } }
        .onAppear { pinFor = model.pinPrompt }
    }

    /// The server has the last word: a PIN set since this list loaded asks for it.
    private func choose(_ profile: Account) {
        Task {
            do {
                try await model.choose(profile)
            } catch AppError.pinRequired {
                pinFor = profile
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var error: String?

    var body: some View {
        @Bindable var model = model
        AccountPage(name: model.serverName) {
            VStack(alignment: .leading, spacing: 40) {
                Text("Settings").font(.system(size: 72, weight: .bold)).padding(.top, 100)
                // The profile's own, on every device it signs in on.
                if let profile = model.activeProfile, profile.kind == .adult {
                    setting(
                        "Hide kids\u{2019} content",
                        "Movies, shows and YouTube channels for kids stay out of your browsing.",
                        Binding(get: { profile.hideKidsContent == true }, set: { hide(profile, $0) }))
                }
                if let error { Text(error).font(.system(size: 28)).foregroundStyle(Theme.amber) }
                setting(
                    "Remember profile",
                    "Open as the last profile used on this Apple TV, without Who\u{2019}s watching.",
                    $model.profileMemory.remember)
                if model.profileMemory.remember {
                    setting(
                        "Skip PIN", "Don\u{2019}t ask for that profile\u{2019}s PIN when Rabbit Ears opens.",
                        $model.profileMemory.skipPin)
                }
            }
            .frame(width: 1100, alignment: .leading)
            .focusSection()
        }
    }

    private func hide(_ profile: Account, _ hiding: Bool) {
        Task {
            do {
                try await model.savePreferences(for: profile, color: nil, hideKidsContent: hiding)
                error = nil
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func setting(_ title: String, _ detail: String, _ isOn: Binding<Bool>) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Button {
                isOn.wrappedValue.toggle()
            } label: {
                HStack {
                    Text(title)
                    Spacer()
                    Text(isOn.wrappedValue ? "On" : "Off").foregroundStyle(Theme.secondary)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(TVButtonStyle())
            .accessibilityValue(isOn.wrappedValue ? "On" : "Off")
            Text(detail).font(.system(size: 26)).foregroundStyle(Theme.secondary)
        }
    }
}

struct ProfileFace: View {
    let profile: Account

    var body: some View {
        VStack(spacing: 40) {
            Avatar(account: profile)
                .overlay(alignment: .bottomTrailing) {
                    if profile.hasPin {
                        Circle().fill(Theme.ground).frame(width: 64, height: 64)
                            .overlay(Image(systemName: "lock").font(.system(size: 28, weight: .bold)))
                            .foregroundStyle(Theme.amber)
                    }
                }
            Text(profile.name).font(.system(size: 32, weight: .semibold))
        }
    }
}

struct ProfileButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.modifier(FocusLift(scale: 1.14, fills: false))
    }
}

/// The keys sit in one row across the screen, as the remote moves best.
struct PinPad: View {
    @Environment(AppModel.self) private var model
    let profile: Account
    let close: () -> Void
    @State private var entry = PinEntry()
    @State private var error: AppError?

    var body: some View {
        ZStack {
            Color.black.opacity(0.75).ignoresSafeArea()
            VStack(spacing: 0) {
                Avatar(account: profile, size: 120)
                Text("Enter \(profile.name)'s PIN").font(.system(size: 48, weight: .bold)).padding(.top, 40)
                HStack(spacing: 28) {
                    ForEach(0..<PinEntry.length, id: \.self) { index in
                        Circle().fill(index < entry.digits.count ? Theme.amber : .white.opacity(0.25))
                            .frame(width: 24, height: 24)
                    }
                }
                .padding(.top, 34)
                .accessibilityElement().accessibilityLabel(entry.accessibilityLabel)
                HStack(spacing: 14) {
                    ForEach(["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"], id: \.self) { digit in
                        Button {
                            if entry.type(Character(digit)) { submit() }
                        } label: {
                            Text(digit)
                        }
                    }
                    Button {
                        entry.deleteBackward()
                    } label: {
                        Image(systemName: "delete.left")
                    }
                    .accessibilityLabel("Delete")
                }
                .buttonStyle(KeyButtonStyle())
                .disabled(error == .pinLocked)
                .padding(.top, 44)
                Text(error?.localizedDescription ?? "Forgot it? An adult in your household can reset it.")
                    .font(.system(size: 26)).foregroundStyle(error == nil ? Theme.secondary : Theme.amber)
                    .padding(.top, 52)
            }
            .padding(.vertical, 52)
            .frame(width: 1192)
            .background(Theme.card, in: .rect(cornerRadius: 36))
            .shadow(color: .black.opacity(0.6), radius: 60, y: 30)
        }
        .onExitCommand(perform: close)
    }

    private func submit() {
        let pin = entry.digits
        Task {
            do {
                try await model.choose(profile, pin: pin)
                close()
            } catch {
                self.error = error as? AppError ?? .server(error.localizedDescription)
                entry.clear()
            }
        }
    }
}

struct KeyButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 40, weight: .semibold))
            .frame(width: 84, height: 84)
            .background(Theme.control, in: .circle)
            .modifier(FocusLift(scale: 1.14))
    }
}
