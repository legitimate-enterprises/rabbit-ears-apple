import Foundation
import GRDB
import RabbitEarsAPI

/// A primary-navigation section backed by a library kind. Home is not one: it always shows.
public enum LibrarySection: String, CaseIterable, Codable, Sendable { case movies, tv, music, youtube }

extension LibrarySection {
    /// The sections to show for the server's library kinds; every section while the kinds are unknown (nil).
    public static func visible(for kinds: [Components.Schemas.LibraryKind]?) -> Set<LibrarySection> {
        guard let kinds else { return Set(allCases) }
        return Set(kinds.compactMap { LibrarySection(rawValue: $0.rawValue) })
    }
}

extension AppModel {
    /// Reads which kinds of library the replica holds; every section before its first snapshot.
    public func loadLibrarySections() async {
        guard let sync else { return }
        let kinds = try? await sync.replica.read { db in
            try String.fetchAll(db, sql: "SELECT DISTINCT kind FROM library")
        }
        guard self.sync === sync else { return }
        librarySections = LibrarySection.visible(
            for: kinds.map { $0.compactMap(Components.Schemas.LibraryKind.init(rawValue:)) })
    }
}
