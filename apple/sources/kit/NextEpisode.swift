import Foundation
import RabbitEarsAPI

extension VideoBrowser {
    /// Plays the next episode in the open player. The request keeps the
    /// cover's identity, since a cover dismissed and presented again in one
    /// pass never comes back; the player inside it is rebuilt per item.
    public func playNext(_ item: Item) {
        playing = PlayRequest(id: playing?.id ?? UUID(), item: item, positionMs: 0)
    }
}
