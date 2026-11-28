import RabbitEarsKit
import SwiftUI

@main
struct RabbitEarsApp: App {
    @UIApplicationDelegateAdaptor private var delegate: AppDelegate

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(AppContext.shared.model)
                .background(Theme.ground)
                .preferredColorScheme(.dark)
                .tint(Theme.amber)
                .task { await AppContext.shared.start() }
        }
    }
}

/// Hands a relaunch for finished background downloads to the downloader.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        // The system's handler is called once, on the main queue, when the session's events are in.
        nonisolated(unsafe) let done = completionHandler
        AppContext.shared.downloader.handleEvents { done() }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        // The splash fades into whatever the launch opens on.
        ZStack { screen }.animation(.easeInOut(duration: 0.4), value: model.phase == .starting)
    }

    @ViewBuilder private var screen: some View {
        switch model.phase {
        case .starting: Splash()
        case .unreachable:
            ContentUnavailableView {
                Label("Can't reach the server", systemImage: "wifi.exclamationmark")
            } description: {
                Text(model.lastServer)
            } actions: {
                Button("Try again") { Task { await model.restore() } }.buttonStyle(SecondaryButtonStyle())
                Button("Sign out") { Task { await model.signOut() } }.buttonStyle(.plain)
                    .foregroundStyle(Theme.secondary)
            }
            .background(Theme.ground)
        case .signedOut: SignInFlow()
        case .choosingHousehold: HouseholdChoiceView()
        case .choosingProfile: WhosWatchingView()
        case .browsing: MainView()
        }
    }
}

/// From launch until the replica holds what this build reads.
struct Splash: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 24) {
            StationGlyph(size: 64)
            if model.libraryUpdate == .unreachable {
                Text("Your library needs an update, and the server can't be reached.")
                    .font(.subheadline).foregroundStyle(Theme.secondary).multilineTextAlignment(.center)
                Button("Try again") { Task { await model.retryLibraryUpdate() } }.buttonStyle(SecondaryButtonStyle())
                Button("Sign out") { Task { await model.signOut() } }.buttonStyle(.plain)
                    .foregroundStyle(Theme.secondary)
            } else {
                ProgressView()
                // Said only once an update takes more than a moment.
                Text("Updating your library…").font(.subheadline).foregroundStyle(Theme.secondary)
                    .opacity(model.libraryUpdate == .updating ? 1 : 0)
                    .animation(.easeIn.delay(1), value: model.libraryUpdate)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.ground)
    }
}
