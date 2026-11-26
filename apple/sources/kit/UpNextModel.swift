import Foundation
import Observation
import RabbitEarsAPI

/// What plays when a movie, episode or video ends, as the server answers
/// it, and Autoplay's countdown to it.
@MainActor
@Observable
public final class UpNextModel {
    public static let countdownSeconds = 10

    /// What the card names: "Up next: \(title)".
    public let title: String
    /// What Play now plays, in the player already open.
    public let request: PlayRequest
    public private(set) var autoplay: Bool
    /// Seconds before the next item plays by itself; nil while Autoplay is off.
    public private(set) var secondsLeft: Int?

    init(title: String, request: PlayRequest, autoplay: Bool) {
        self.title = title
        self.request = request
        self.autoplay = autoplay
    }

    /// Asks what follows `ended` for the profile: nil for nothing, an
    /// unreadable answer, or a Watch together, which only closes.
    public static func load(after ended: PlayRequest, client: Client, profile: Account) async -> UpNextModel? {
        guard ended.together == nil,
            let response = try? await client.getUpNext(
                path: .init(profileId: profile.id, itemId: ended.item.id),
                query: .init(playlistId: ended.queue?.playlistId, index: ended.queue?.index)),
            case .ok(let ok) = response, let next = try? ok.body.json
        else { return nil }
        let request: PlayRequest
        if let index = next.index, let queue = ended.queue?.at(index) {
            request = PlayRequest(
                id: ended.id, item: queue.current, editionId: queue.editionId, positionMs: 0, queue: queue)
        } else if let video = next.video {
            request = PlayRequest(id: ended.id, item: Item(video: video), positionMs: 0)
        } else if let item = next.item {
            request = PlayRequest(id: ended.id, item: item, editionId: next.editionId, positionMs: 0)
        } else {
            return nil
        }
        return UpNextModel(title: next.title, request: request, autoplay: profile.autoplay ?? true)
    }

    /// Counts down a second at a time while Autoplay is on. True once it
    /// reaches zero; false when Autoplay is off or the wait is cancelled.
    public func countdown(tick: () async throws -> Void = { try await Task.sleep(for: .seconds(1)) }) async -> Bool {
        secondsLeft = autoplay ? Self.countdownSeconds : nil
        while autoplay, let left = secondsLeft, left > 0 {
            do { try await tick() } catch { return false }
            guard autoplay else { return false }
            secondsLeft = left - 1
        }
        return autoplay
    }

    /// Turns Autoplay on or off for the active profile on every device; a
    /// view restarts `countdown` when it changes.
    public func setAutoplay(_ on: Bool, model: AppModel) async {
        autoplay = on
        if !on { secondsLeft = nil }
        guard let profile = model.activeProfile else { return }
        try? await model.savePreferences(for: profile, color: nil, hideKidsContent: nil, autoplay: on)
    }
}
