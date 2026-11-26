import Foundation

extension LibrarySection {
    /// The section to be in once `visible` is known: the selected one while
    /// it shows, else Home, which is nil.
    public static func selection(_ selected: LibrarySection?, in visible: Set<LibrarySection>) -> LibrarySection? {
        selected.flatMap { visible.contains($0) ? $0 : nil }
    }
}

extension AppModel {
    /// What a pull to refresh calls: `reload` asks the server again rather
    /// than reading what is kept, as do the libraries behind the primary
    /// navigation, and this returns once both have applied their answers.
    public func pull(_ reload: @escaping @MainActor () async -> Void) async {
        await live.pull {
            async let libraries: Void = self.loadLibrarySections()
            await reload()
            await libraries
        }
    }
}
