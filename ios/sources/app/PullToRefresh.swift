import RabbitEarsKit
import SwiftUI

/// The reload a pull runs for the list showing. The scroll view that pulls
/// is the list's parent, so the list registers how it reloads its own rows.
@MainActor
@Observable
final class Reloader {
    @ObservationIgnored var action: (@MainActor () async -> Void)?
}

extension View {
    /// Pull to refresh: the server is asked again rather than the kept answer
    /// read, and the spinner stays until `reload` has applied what it said.
    /// Rows stay as they are while it runs, and when it fails.
    func pulling(_ reload: @escaping @MainActor () async -> Void) -> some View { modifier(Pulling(reload: reload)) }

    /// A list under a `Reloader` environment says how a pull reloads it.
    func reloads(_ reload: @escaping @MainActor () async -> Void) -> some View { modifier(Reloads(reload: reload)) }
}

private struct Pulling: ViewModifier {
    @Environment(AppModel.self) private var app
    let reload: @MainActor () async -> Void

    func body(content: Content) -> some View {
        content.refreshable { await app.pull(reload) }
    }
}

private struct Reloads: ViewModifier {
    @Environment(Reloader.self) private var reloader: Reloader?
    let reload: @MainActor () async -> Void

    func body(content: Content) -> some View {
        content.onAppear { reloader?.action = reload }
    }
}
