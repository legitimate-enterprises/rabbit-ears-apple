import Foundation
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
    /// The last answer for a server, so a launch does not show entries and then take them away.
    static func rememberedLibrarySections(_ server: URL) -> Set<LibrarySection> {
        let kinds = UserDefaults.standard.stringArray(forKey: "librarySections \(server.absoluteString)")
        return LibrarySection.visible(for: kinds.map { $0.compactMap(Components.Schemas.LibraryKind.init(rawValue:)) })
    }

    /// Asks the server which kinds of library it has; a failed answer keeps what is known.
    public func loadLibrarySections() async {
        guard let client, let server = endpoint?.baseURL else { return }
        guard
            let kinds = try? await allPages({ offset in
                let page = try await client.listLibraries(query: .init(limit: 200, offset: offset)).ok.body.json
                return (page.items.map(\.kind), page.nextOffset)
            })
        else { return }
        guard endpoint?.baseURL == server else { return }
        librarySections = LibrarySection.visible(for: kinds)
        UserDefaults.standard.set(kinds.map(\.rawValue), forKey: "librarySections \(server.absoluteString)")
    }
}
