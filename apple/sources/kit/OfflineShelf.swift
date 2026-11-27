import Foundation
import RabbitEarsAPI

/// The artwork kept for what is downloaded, which screens show while the
/// server cannot be reached.
struct OfflineShelf: Codable, Sendable {
    /// Artwork file names kept, by the key `ArtKey` makes.
    var art: Set<String> = []
}

/// An artwork file's name: `item-<id>-poster` or `collection-<id>-backdrop`.
struct ArtKey: Equatable {
    let id: UID
    let kind: ArtworkStore.Kind
    let collection: Bool

    init(id: UID, kind: ArtworkStore.Kind, collection: Bool = false) {
        self.id = id
        self.kind = kind
        self.collection = collection
    }

    init?(file: String) {
        // The id's own four dashes split it in five.
        let parts = file.split(separator: "-")
        guard parts.count == 7, let id = UID(parts[1...5].joined(separator: "-")),
            let kind = ArtworkStore.Kind(rawValue: String(parts[6]))
        else { return nil }
        self.init(id: id, kind: kind, collection: parts[0] == "collection")
    }

    var file: String { "\(collection ? "collection" : "item")-\(id)-\(kind.rawValue)" }
}
