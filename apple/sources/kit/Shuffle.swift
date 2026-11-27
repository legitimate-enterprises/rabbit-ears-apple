import Foundation
import RabbitEarsAPI

extension VideoQueue {
    /// Shuffle on a show, season or collection: each of `items` the server
    /// has a file for, once, in one order fixed now, each in its default
    /// edition. Nil when none has.
    public init?(shuffling items: [Item], order: ([Item]) -> [Item] = { $0.shuffled() }) {
        let rows = order(items.filter(Self.shuffles)).map {
            PlayOrderRow(entryId: $0.id, itemId: $0.id, kind: $0.kind == .movie ? .movie : .episode, item: $0)
        }
        self.init(rows, start: 0, playlistId: nil)
    }

    public static func shuffles(_ item: Item) -> Bool { item.unavailable != true }

    public var isShuffle: Bool { playlistId == nil }
}

extension VideoBrowser {
    /// Plays a Shuffle of `items`, every row from its start; while the
    /// server cannot be reached, only what `downloads` has on the device.
    public func shuffle(
        _ items: [Item], downloads: DownloadStore?, profile: UID, order: ([Item]) -> [Item] = { $0.shuffled() }
    ) {
        let kept =
            if let downloads, downloads.isOffline {
                items.filter { downloads.onDevice($0.id, profile: profile) != nil }
            } else {
                items
            }
        guard let queue = VideoQueue(shuffling: kept, order: order) else { return }
        playing = PlayRequest(item: queue.current, editionId: queue.editionId, positionMs: 0, queue: queue)
    }
}

extension PlayRequest {
    /// What Next plays in a Shuffle: its next row the catalog still has a
    /// file for, from its start in the same cover; nil after the last row
    /// and outside a Shuffle.
    public func shuffleNext(in catalog: Catalog) -> PlayRequest? {
        guard let queue, queue.isShuffle,
            let row = queue.items.indices.dropFirst(queue.index + 1).first(where: {
                catalog.item(queue.items[$0].id).map(VideoQueue.shuffles) ?? true
            }),
            let next = queue.at(row)
        else { return nil }
        return PlayRequest(id: id, item: next.current, editionId: next.editionId, positionMs: 0, queue: next)
    }
}
