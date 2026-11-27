import Foundation
import RabbitEarsAPI

/// The artwork kept for what is downloaded, which screens show while the
/// server cannot be reached.
struct OfflineShelf: Codable, Sendable {
    /// Artwork file names kept, by the key `ArtKey` makes.
    var art: Set<String> = []
}

/// An artwork file's name: `item-12-poster` or `collection-3-backdrop`.
struct ArtKey: Equatable {
    let id: Int64
    let kind: ArtworkStore.Kind
    let collection: Bool

    init(id: Int64, kind: ArtworkStore.Kind, collection: Bool = false) {
        self.id = id
        self.kind = kind
        self.collection = collection
    }

    init?(file: String) {
        let parts = file.split(separator: "-")
        guard parts.count == 3, let id = Int64(parts[1]), let kind = ArtworkStore.Kind(rawValue: String(parts[2]))
        else { return nil }
        self.init(id: id, kind: kind, collection: parts[0] == "collection")
    }

    var file: String { "\(collection ? "collection" : "item")-\(id)-\(kind.rawValue)" }
}
