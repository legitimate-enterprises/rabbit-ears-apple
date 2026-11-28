import Foundation
import RabbitEarsAPI

/// The artwork kept for what is downloaded, which screens show while the
/// server cannot be reached.
struct OfflineShelf: Codable, Sendable {
    /// Artwork file names kept, as `file` names them.
    var art: Set<String> = []

    /// The file of the image at a getArtwork path: `w500-a.jpg`. No store has a dash in its name.
    static func file(_ path: Operations.GetArtwork.Input.Path) -> String { "\(path.store.rawValue)-\(path.name)" }
}
