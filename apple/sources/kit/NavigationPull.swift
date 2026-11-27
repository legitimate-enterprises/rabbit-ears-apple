import Foundation

extension LibrarySection {
    /// The section to be in once `visible` is known: the selected one while
    /// it shows, else Home, which is nil.
    public static func selection(_ selected: LibrarySection?, in visible: Set<LibrarySection>) -> LibrarySection? {
        selected.flatMap { visible.contains($0) ? $0 : nil }
    }
}

extension AppModel {
    /// What a pull to refresh calls: the replica catches up with the
    /// server, then `reload` and the libraries behind the primary navigation
    /// read it again, and this returns once both have. It runs on its own
    /// task, so a pull that the system cancels, as a view redrawing under
    /// it, does not stop half-way and leave the old data.
    public func pull(_ reload: @escaping @MainActor () async -> Void) async {
        let engine = sync?.engine
        await Task {
            try? await engine?.catchUp()
            async let libraries: Void = self.loadLibrarySections()
            await reload()
            await libraries
        }.value
    }
}
