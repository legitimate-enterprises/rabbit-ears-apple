import Foundation
import RabbitEarsAPI

/// What the video player is asked to play.
public struct PlayRequest: Identifiable {
    public var id: UUID
    public let item: Item
    public var audioTrackId: Int64?
    /// Nil plays the default edition.
    public var editionId: Int64?
    public var positionMs: Int64?
    public var together: WatchTogetherModel?
    /// The movies or tv playlist this is a row of; its end plays the next row.
    public var queue: VideoQueue?

    public init(
        id: UUID = UUID(), item: Item, audioTrackId: Int64? = nil, editionId: Int64? = nil, positionMs: Int64? = nil,
        together: WatchTogetherModel? = nil, queue: VideoQueue? = nil
    ) {
        self.id = id
        self.item = item
        self.audioTrackId = audioTrackId
        self.editionId = editionId
        self.positionMs = positionMs
        self.together = together
        self.queue = queue
    }
}

/// Each app's navigation model, which presents the player for `playing`.
@MainActor
public protocol VideoBrowser: AnyObject {
    var playing: PlayRequest? { get set }
}

extension VideoBrowser {
    /// The player up already watches the title together; the details page
    /// behind it, hearing of the same Watch together, starts no second one.
    public func watchesTogether(_ itemId: Item.ID) -> Bool {
        playing?.together != nil && playing?.item.id == itemId
    }

    /// Plays a movie or episode; a show or season plays its resume target.
    /// Without `edition` it resumes the edition the position belongs to.
    public func play(
        _ item: Item, in catalog: Catalog, audioTrackId: Int64? = nil, edition: Int64?? = .none,
        from positionMs: Int64? = nil, together: WatchTogetherModel? = nil
    ) {
        let target = item.kind == .show || item.kind == .season ? catalog.resumeTarget(for: item.id) : item
        guard let target, together == nil || !watchesTogether(target.id) else { return }
        playing = PlayRequest(
            item: target, audioTrackId: audioTrackId,
            editionId: Editions.started(edition, item: target.id, in: catalog, together: together != nil),
            positionMs: positionMs, together: together)
    }
}
