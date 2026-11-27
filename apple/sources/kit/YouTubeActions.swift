import Foundation
import GRDB
import RabbitEarsAPI

extension YouTubeModel {
    /// putYouTubeChannelWatchState through the queue: every video of the
    /// channel marked at once, as the server marks each (watchstate.Mark,
    /// position 0) unless its state changed after this. A channel of more
    /// videos than an action may name is marked on the server at once.
    func markChannel(_ channel: UID, watched: Bool) async throws {
        let profile = profileId
        let videos = try await replica.read { db in
            try UID.fetchAll(
                db, sql: "SELECT id FROM item WHERE kind = 'video' AND parent_id = ?", arguments: [channel])
        }
        try await queue.act(
            as: profile,
            touching: try videos.map { try ActionQueue.watchKey(profile, $0) },
            call: { client, at in
                _ = try await client.putYouTubeChannelWatchState(
                    path: .init(profileId: profile, channelId: channel),
                    body: .json(.init(watched: watched, at: at))
                ).noContent
            },
            apply: { db, at in try ActionQueue.mark(db, profile, videos, watched: watched, at: at) })
    }
}
