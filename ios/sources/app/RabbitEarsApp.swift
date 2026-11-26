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
        switch model.phase {
        case .starting: ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
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
