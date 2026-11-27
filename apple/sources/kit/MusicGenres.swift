import Foundation
import RabbitEarsAPI

extension MusicModel {
    /// The genre picker's options: the genres of music libraries only, by name.
    public func musicGenres() async throws -> [Genre] {
        try await read { db, me in try MusicRows.genres(db, me) }.sorted { $0.name < $1.name }
    }
}
