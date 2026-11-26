import Foundation
import RabbitEarsAPI

extension MusicModel {
    /// The genre picker's options: the genres of music libraries only, by name.
    public func musicGenres() async throws -> [Genre] {
        do {
            let libraries = try await allPages { offset in
                let page = try await self.client.listLibraries(query: .init(limit: 200, offset: offset))
                    .ok.body.json
                return (page.items.filter { $0.kind == .music }, page.nextOffset)
            }
            var genres: [Genre] = []
            for library in libraries {
                genres += try await allPages { offset in
                    let page = try await self.client.listGenres(
                        query: .init(libraryId: library.id, limit: 200, offset: offset)
                    ).ok.body.json
                    return (page.items, page.nextOffset)
                }
            }
            return Dictionary(grouping: genres, by: \.id).values.compactMap(\.first).sorted { $0.name < $1.name }
        } catch {
            throw AppError.from(error, unauthorized: .signedOut)
        }
    }
}
