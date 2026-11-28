import Foundation
import GRDB
import Observation
import RabbitEarsAPI

/// What Friends says. None of it tells whether an email belongs to anyone.
public enum FriendsText {
    /// Every send that the server took says this, whoever holds the email.
    public static let sent = "If they're on this server, they'll get your friend request."
    public static let invalidEmail = "Enter a valid email address."
    public static let tooMany = "You've sent a lot of requests today. Try again later."
    public static let noLongerAdded = "This person can no longer be added."
    public static let wants = "Wants to be friends"
    public static let none = "No friends yet. Add someone by their email to share playlists and watch together."
    public static let help = "Friends can share playlists and watch together with you. They don't join your household."
    public static let removeMessage =
        "They won't be told. Playlists you've shared stay shared until you stop sharing them."

    public static func removeTitle(_ name: String) -> String { "Remove \(name)?" }

    /// The email's syntax alone, once trimmed.
    public static func isEmail(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .wholeMatch(of: /[^@\s]+@[^@\s.]+(\.[^@\s.]+)+/) != nil
    }
}

/// A friend, or the sender of a request: their name and color only.
public struct FriendCard: Identifiable, Hashable, Sendable {
    public let id: UID
    public let name: String
    /// 0xRRGGBB; one with no color of its own wears the palette's for its id, as the server shows it.
    public let rgb: UInt32

    init(id: UID, name: String, color: String?) {
        self.id = id
        self.name = name
        rgb = color.flatMap(ProfilePalette.rgb) ?? ProfilePalette.placeholder(id)
    }
}

public struct ReceivedFriendRequest: Identifiable, Hashable, Sendable {
    public let id: UID
    public let from: FriendCard
    public var name: String { from.name }
    public var rgb: UInt32 { from.rgb }
}

/// A request as its sender wrote it, the same whatever became of it.
public struct SentFriendRequest: Identifiable, Hashable, Sendable {
    public let id: UID
    public let email: String
    public let createdAt: Date
    public let expiresAt: Date

    /// "Sent Mar 1, 2026 · Expires Mar 31, 2026".
    public var dates: String {
        "Sent \(createdAt.formatted(date: .abbreviated, time: .omitted))"
            + " · Expires \(expiresAt.formatted(date: .abbreviated, time: .omitted))"
    }
}

/// The active adult's requests and friends as the replica holds them, which
/// are what listFriendRequests and listFriends answer them. The replica is
/// the household's, so rows of its other members are left out.
public struct FriendLists: Sendable, Equatable {
    public var received: [ReceivedFriendRequest] = []
    public var sent: [SentFriendRequest] = []
    public var friends: [FriendCard] = []

    public init() {}

    /// Received leaves out what is expired, declined, from a friend, or
    /// from a sender whose card is missing or revoked, which accepting
    /// would refuse. A purged row lags its expiry by up to an hour.
    public static func read(_ db: Database, for me: UID, at now: Date) throws -> FriendLists {
        var lists = FriendLists()
        let at = ActionQueue.ms(now)
        lists.received = try Row.fetchAll(
            db,
            sql: """
                SELECT r.id, r.from_id, c.name, c.color FROM friend_request_in r
                JOIN account_card c ON c.id = r.from_id AND c.revoked_at IS NULL
                WHERE r.to_id = ?1 AND r.expires_at > ?2
                    AND NOT EXISTS (SELECT 1 FROM friend_request_decline d
                        WHERE d.account_id = ?1 AND d.request_id = r.id)
                    AND NOT EXISTS (SELECT 1 FROM friendship f
                        WHERE (f.a_id = ?1 AND f.b_id = r.from_id) OR (f.b_id = ?1 AND f.a_id = r.from_id))
                ORDER BY r.created_at DESC, r.id DESC
                """, arguments: [me, at]
        ).map { .init(id: $0["id"], from: .init(id: $0["from_id"], name: $0["name"], color: $0["color"])) }
        lists.sent = try Row.fetchAll(
            db,
            sql: """
                SELECT id, email, created_at, expires_at FROM friend_request WHERE from_id = ? AND expires_at > ?
                ORDER BY created_at DESC, id DESC
                """, arguments: [me, at]
        ).map {
            .init(
                id: $0["id"], email: $0["email"], createdAt: Self.date($0["created_at"]),
                expiresAt: Self.date($0["expires_at"]))
        }
        lists.friends = try Row.fetchAll(
            db,
            sql: """
                SELECT c.id, c.name, c.color FROM friendship f
                JOIN account_card c ON c.id = CASE WHEN f.a_id = ?1 THEN f.b_id ELSE f.a_id END
                WHERE (f.a_id = ?1 OR f.b_id = ?1) AND c.revoked_at IS NULL AND NOT COALESCE(c.pending, 0)
                ORDER BY c.name COLLATE NOCASE, c.id
                """, arguments: [me]
        ).map { .init(id: $0["id"], name: $0["name"], color: $0["color"]) }
        return lists
    }

    private static func date(_ ms: Int64) -> Date { Date(timeIntervalSince1970: Double(ms) / 1000) }
}

/// The active adult's Friends, from the replica. Accepting is made on the
/// server at once, as it does not replay; the rest is queued, and a send
/// is too when the server cannot be reached. A kid has none of it.
@MainActor
@Observable
public final class FriendsModel {
    public enum SendError: Error, LocalizedError {
        case invalidEmail, tooMany

        public var errorDescription: String? { self == .invalidEmail ? FriendsText.invalidEmail : FriendsText.tooMany }
    }

    public private(set) var lists = FriendLists()
    /// A line to show for a while, as after a send.
    public private(set) var notice: String?
    public private(set) var error: String?
    /// Requests the server said cannot be accepted, or were, until the replica drops them.
    private var gone: Set<UID> = []
    private let app: AppModel

    public init(app: AppModel) { self.app = app }

    /// Whether Friends shows at all: only for an adult.
    public var offered: Bool { me != nil }
    public var received: [ReceivedFriendRequest] { lists.received.filter { !gone.contains($0.id) } }
    public var sent: [SentFriendRequest] { lists.sent }
    public var friends: [FriendCard] { lists.friends }

    private var me: UID? { app.serverActiveProfile.flatMap { $0.kind == .adult ? $0.id : nil } }

    public func load() async {
        guard let me, let replica = app.sync?.replica else {
            lists = FriendLists()
            return
        }
        let now = Date()
        lists = (try? await replica.read { try FriendLists.read($0, for: me, at: now) }) ?? FriendLists()
    }

    /// Says `FriendsText.sent` on every send taken, and when the adult's own
    /// live request to the email stands, which is sent nothing. Throws the
    /// line to show under the field.
    public func send(_ email: String) async throws {
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard FriendsText.isEmail(email) else { throw SendError.invalidEmail }
        guard let me, let sync = app.sync else { return }
        let now = ActionQueue.ms(Date())
        let standing = try? await sync.replica.read {
            try Bool.fetchOne(
                $0,
                sql: "SELECT EXISTS (SELECT 1 FROM friend_request WHERE from_id = ? AND email = ? AND expires_at > ?)",
                arguments: [me, email, now])
        }
        if standing != true {
            do {
                try await post(email)
                try? await sync.engine.catchUp()
            } catch AppError.unreachable {
                try await sync.queue.sendFriendRequest(.new(), to: email, as: me)
            }
        }
        notice = FriendsText.sent
        await load()
    }

    /// A client id in use is the only conflict, so one more under a new id
    /// is taken whatever it answers.
    private func post(_ email: String) async throws {
        let client = try app.signedInClient()
        for retry in [false, true] {
            do {
                _ = try await client.sendFriendRequest(body: .json(.init(id: .new(), email: email))).accepted
                return
            } catch {
                switch APIError.from(error)?.code {
                case .conflict: if retry { return }
                case .badRequest: throw SendError.invalidEmail
                case .tooManyRequests: throw SendError.tooMany
                default: throw AppError.from(error, unauthorized: .signedOut)
                }
            }
        }
    }

    /// Online only. A request the server no longer lists goes silently; one
    /// whose sender can no longer be a friend says so.
    public func accept(_ request: ReceivedFriendRequest) async {
        do {
            _ = try await app.signedInClient().acceptFriendRequest(path: .init(requestId: request.id)).noContent
            gone.insert(request.id)
            error = nil
            try? await app.sync?.engine.catchUp()
        } catch {
            switch APIError.from(error)?.code {
            case .notFound:
                gone.insert(request.id)
                self.error = nil
            case .conflict:
                gone.insert(request.id)
                notice = FriendsText.noLongerAdded
                self.error = nil
            default: self.error = AppError.from(error, unauthorized: .signedOut).localizedDescription
            }
        }
        await load()
    }

    public func decline(_ request: ReceivedFriendRequest) async {
        await queued { try await $0.declineFriendRequest(request.id, as: $1) }
    }

    public func withdraw(_ request: SentFriendRequest) async {
        await queued { try await $0.withdrawFriendRequest(request.id, as: $1) }
    }

    public func remove(_ friend: FriendCard) async {
        await queued { try await $0.deleteFriend(friend.id, as: $1) }
    }

    private func queued(_ action: (ActionQueue, UID) async throws -> Void) async {
        guard let me, let queue = app.sync?.queue else { return }
        do {
            try await action(queue, me)
            error = nil
        } catch {
            self.error = AppError.from(error, unauthorized: .signedOut).localizedDescription
        }
        await load()
    }
}
