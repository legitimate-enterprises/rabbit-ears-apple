import Foundation
import GRDB
import RabbitEarsAPI
import XCTest

@testable import RabbitEarsKit

extension Database {
    /// A profile of another household as its card shows it.
    func friend(_ id: UID, _ name: String, color: String? = nil, revoked: Bool = false, pending: Bool = false) throws {
        try execute(
            sql: """
                INSERT INTO account_card(id, name, kind, color, household_id, revoked_at, pending)
                VALUES (?, ?, 'adult', ?, ?, ?, ?)
                """, arguments: [id, name, color, UID.n(8), revoked ? 1000 : nil, pending])
    }

    func friendship(_ first: UID, _ second: UID) throws {
        try execute(sql: "INSERT INTO friendship VALUES (?, ?, 1000)", arguments: [first, second])
    }

    func requestIn(_ id: UID, from: UID, to: UID, created: String, expires: String = "2099-01-01T00:00:00Z") throws {
        try execute(
            sql: "INSERT INTO friend_request_in VALUES (?, ?, ?, ?, ?)",
            arguments: [id, from, Self.ms(created), Self.ms(expires), to])
    }

    func requestOut(
        _ id: UID, from: UID, _ email: String, created: String, expires: String = "2099-01-01T00:00:00Z"
    ) throws {
        try execute(
            sql: "INSERT INTO friend_request VALUES (?, ?, ?, ?, ?)",
            arguments: [id, from, email, Self.ms(created), Self.ms(expires)])
    }

    func decline(_ request: UID, by account: UID) throws {
        try execute(sql: "INSERT INTO friend_request_decline VALUES (?, ?, 1000)", arguments: [account, request])
    }
}

/// Friends and friend requests of the active adult, read from the replica
/// and written through the queue, or the server where it does not replay.
@MainActor
final class FriendsTests: XCTestCase {
    var app: SyncedApp!

    override func setUp() async throws {
        app = try SyncedApp { db in
            try db.member(1, "Avery")
            try db.member(2, "Robin", kind: "kid", pin: true)
            try db.member(3, "Cy")
            try db.friend(10, "zed", color: "#2E6B5B")
            try db.friend(11, "Bea")
            try db.friend(12, "Gone", revoked: true)
            try db.friend(13, "Invited", pending: true)
            try db.friend(14, "Dana")
            try db.friend(15, "Eli", revoked: true)
            try db.friend(16, "Fay")
            try db.friend(17, "Gus")
            try db.friend(18, "Hal")
            // Stored either way round.
            try db.friendship(1, 10)
            try db.friendship(11, 1)
            try db.friendship(1, 12)
            try db.friendship(13, 1)
            try db.friendship(3, 18)
            try db.requestIn(40, from: 14, to: 1, created: "2026-02-01T00:00:00Z")
            try db.requestIn(41, from: 16, to: 1, created: "2026-03-01T00:00:00Z")
            try db.requestIn(42, from: 15, to: 1, created: "2026-03-02T00:00:00Z")
            try db.requestIn(43, from: 11, to: 1, created: "2026-03-03T00:00:00Z")
            try db.requestIn(44, from: 17, to: 1, created: "2026-03-04T00:00:00Z")
            try db.requestIn(45, from: 17, to: 1, created: "2025-12-01T00:00:00Z", expires: "2025-12-31T00:00:00Z")
            try db.requestIn(46, from: 18, to: 3, created: "2026-03-05T00:00:00Z")
            try db.requestIn(47, from: 99, to: 1, created: "2026-03-06T00:00:00Z")
            try db.decline(44, by: 1)
            try db.decline(46, by: 3)
            try db.requestOut(50, from: 1, "pat@example.test", created: "2026-02-01T00:00:00Z")
            try db.requestOut(51, from: 1, "Lee@Example.test", created: "2026-04-01T00:00:00Z")
            try db.requestOut(
                52, from: 1, "old@example.test", created: "2025-12-01T00:00:00Z", expires: "2025-12-31T00:00:00Z")
            try db.requestOut(53, from: 3, "cys@example.test", created: "2026-05-01T00:00:00Z")
        }
        app.routes.routes["POST /profiles/\(UID.n(1))/unlock"] = (.noContent, "")
        app.routes.routes["POST /profiles/\(UID.n(2))/unlock"] = (.noContent, "")
    }

    override func tearDown() { app.remove() }

    private func loaded() async throws -> FriendsModel {
        _ = try await app.synced()
        let model = FriendsModel(app: app.model)
        await model.load()
        return model
    }

    func testReceivedAreTheActiveAdultsOwnLiveRequestsNewestFirst() async throws {
        let model = try await loaded()
        XCTAssertEqual(
            model.received.map(\.id), [41, 40],
            "not another member's, expired, declined, from a friend, a revoked card or one missing")
        XCTAssertEqual(model.received.map(\.name), ["Fay", "Dana"])
        XCTAssertEqual(model.received.first?.rgb, ProfilePalette.placeholder(16), "no color is the server's by id")
    }

    func testSentAreTheActiveAdultsOwnUnexpiredRequestsNewestFirstWithNoStatus() async throws {
        let model = try await loaded()
        XCTAssertEqual(model.sent.map(\.id), [51, 50])
        XCTAssertEqual(model.sent.map(\.email), ["Lee@Example.test", "pat@example.test"])
        let lines = model.sent.map(\.dates)
        XCTAssertTrue(lines.allSatisfy { $0.hasPrefix("Sent ") && $0.contains(" · Expires ") }, "\(lines)")
    }

    func testFriendsAreEitherSideOfAFriendshipJoinedNotRevokedByNameIgnoringCase() async throws {
        let model = try await loaded()
        XCTAssertEqual(model.friends.map(\.name), ["Bea", "zed"])
        XCTAssertEqual(model.friends.last?.rgb, 0x2E6B5B)
        XCTAssertEqual(model.friends.first?.rgb, ProfilePalette.placeholder(11))
    }

    func testAKidHasNoFriendsRequestsOrCounts() async throws {
        _ = try await app.synced()
        let robin = try XCTUnwrap(app.model.profiles.first { $0.id == 2 })
        try await app.model.choose(robin, pin: "1234")
        let model = FriendsModel(app: app.model)
        await model.load()
        XCTAssertFalse(model.offered)
        XCTAssertEqual([model.received.count, model.sent.count, model.friends.count], [0, 0, 0])
        try await model.send("pat@example.test")
        XCTAssertFalse(app.routes.paths(.post).contains("/friend-requests"))
        let queued = try await app.queued()
        XCTAssertEqual(queued, [])
    }

    func testSendingToOnesOwnLiveRequestSendsNothingAndSaysTheSame() async throws {
        let model = try await loaded()
        try await model.send("  PAT@example.test ")
        XCTAssertEqual(model.notice, FriendsText.sent)
        XCTAssertFalse(app.routes.paths(.post).contains("/friend-requests"))
        let queued = try await app.queued()
        XCTAssertEqual(queued, [])
        XCTAssertEqual(model.sent.count, 2)
    }

    func testEveryAcceptedSendSaysTheSameLineWhateverTheAnswer() async throws {
        let model = try await loaded()
        for (email, answered) in [("new@example.test", 60), ("other@example.test", 50)] {
            app.routes.routes["POST /friend-requests"] = (
                .accepted,
                #"{"id":"\#(UID.n(answered))","email":"\#(email)","createdAt":"2026-06-01T00:00:00Z","#
                    + #""expiresAt":"2026-07-01T00:00:00Z"}"#
            )
            try await model.send(" \(email)")
            XCTAssertEqual(model.notice, "If they're on this server, they'll get your friend request.")
            XCTAssertEqual(app.routes.json(.post, "/friend-requests")?["email"] as? String, email)
        }
        XCTAssertEqual(model.sent.count, 2, "the server's own row comes by sync")
    }

    func testAMalformedEmailIsRefusedHereAndByTheServerWithTheSameLine() async throws {
        let model = try await loaded()
        for email in ["", "pat", "pat@", "@example.test", "pat@example", "p at@example.test"] {
            XCTAssertFalse(FriendsText.isEmail(email), email)
        }
        XCTAssertTrue(FriendsText.isEmail(" pat@example.test "))
        do {
            try await model.send("pat@")
            XCTFail("sent")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Enter a valid email address.")
        }
        XCTAssertFalse(app.routes.paths(.post).contains("/friend-requests"))
        app.routes.routes["POST /friend-requests"] = (.badRequest, Fixtures.error("bad_request"))
        do {
            try await model.send("pat@example.invalid")
            XCTFail("sent")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Enter a valid email address.")
        }
        XCTAssertNil(model.notice)
    }

    func testTooManySendsSaysSoInline() async throws {
        let model = try await loaded()
        app.routes.routes["POST /friend-requests"] = (.tooManyRequests, Fixtures.error("too_many_requests"))
        do {
            try await model.send("new@example.test")
            XCTFail("sent")
        } catch {
            XCTAssertEqual(error.localizedDescription, "You've sent a lot of requests today. Try again later.")
        }
        XCTAssertNil(model.notice)
    }

    func testAClientIdInUseIsSentOnceMoreUnderANewOneThenSaysTheSame() async throws {
        let model = try await loaded()
        app.routes.routes["POST /friend-requests"] = (.conflict, Fixtures.error("conflict"))
        try await model.send("new@example.test")
        XCTAssertEqual(model.notice, FriendsText.sent)
        let ids = app.routes.sent.filter { $0.path == "/friend-requests" }.map { sent in
            ((try? JSONSerialization.jsonObject(with: Data(sent.body.utf8))) as? [String: Any])?["id"] as? String
        }
        XCTAssertEqual(ids.count, 2)
        XCTAssertNotEqual(ids.first, ids.last)
    }

    func testOfflineASendIsQueuedAndShownAtOnce() async throws {
        let model = try await loaded()
        app.offline()
        try await model.send(" new@example.test ")
        XCTAssertEqual(model.notice, FriendsText.sent)
        XCTAssertEqual(model.sent.first?.email, "new@example.test")
        let sent = try XCTUnwrap(model.sent.first)
        XCTAssertEqual(sent.expiresAt.timeIntervalSince(sent.createdAt), 30 * 86400, accuracy: 0.001)
        let queued = try await app.queued()
        XCTAssertEqual(queued, ["sendFriendRequest POST /friend-requests"])
        let touched = try await app.touched()
        XCTAssertEqual(touched, ["friend_request \(sent.id)"])
    }

    func testDeclineWithdrawAndRemoveAreQueuedAndApplyHereAtOnce() async throws {
        let model = try await loaded()
        app.offline()
        await model.decline(try XCTUnwrap(model.received.first { $0.id == 40 }))
        XCTAssertEqual(model.received.map(\.id), [41])
        await model.withdraw(try XCTUnwrap(model.sent.first { $0.id == 50 }))
        XCTAssertEqual(model.sent.map(\.id), [51])
        await model.remove(try XCTUnwrap(model.friends.first { $0.id == 11 }))
        XCTAssertEqual(model.friends.map(\.id), [10])
        XCTAssertNil(model.error)
        let queued = try await app.queued()
        XCTAssertEqual(
            queued,
            [
                "deleteFriendRequest DELETE /friend-requests/\(UID.n(40))",
                "deleteFriendRequest DELETE /friend-requests/\(UID.n(50))",
                "deleteFriend DELETE /friends/\(UID.n(11))",
            ])
        let touched = try await app.touched()
        XCTAssertEqual(
            touched,
            [
                "friend_request_decline \(UID.n(1))/\(UID.n(40))", "friend_request \(UID.n(50))",
                "friendship \(UID.n(1))/\(UID.n(11))",
            ], "the friendship's ids as stored")
    }

    func testAcceptIsMadeOnTheServerAndNeverQueued() async throws {
        let model = try await loaded()
        app.routes.routes["POST /friend-requests/\(UID.n(41))/accept"] = (.noContent, "")
        await model.accept(try XCTUnwrap(model.received.first { $0.id == 41 }))
        XCTAssertEqual(model.received.map(\.id), [40])
        XCTAssertNil(model.error)
        XCTAssertNil(model.notice)

        app.offline()
        await model.accept(try XCTUnwrap(model.received.first))
        XCTAssertEqual(model.error, AppError.unreachable.localizedDescription)
        XCTAssertEqual(model.received.map(\.id), [40], "still there to accept online")
        let queued = try await app.queued()
        XCTAssertEqual(queued, [])
    }

    func testAnAcceptRefusedRemovesTheRowAndOnlyAConflictSaysWhy() async throws {
        let model = try await loaded()
        app.routes.routes["POST /friend-requests/\(UID.n(41))/accept"] = (.notFound, Fixtures.error("not_found"))
        await model.accept(try XCTUnwrap(model.received.first { $0.id == 41 }))
        XCTAssertEqual(model.received.map(\.id), [40])
        XCTAssertNil(model.notice)
        XCTAssertNil(model.error)
        app.routes.routes["POST /friend-requests/\(UID.n(40))/accept"] = (.conflict, Fixtures.error("conflict"))
        await model.accept(try XCTUnwrap(model.received.first))
        XCTAssertEqual(model.received, [])
        XCTAssertEqual(model.notice, "This person can no longer be added.")
        XCTAssertNil(model.error)
    }

    func testTheRemoveConfirmationSaysNothingIsTold() {
        XCTAssertEqual(FriendsText.removeTitle("Bea"), "Remove Bea?")
        XCTAssertEqual(
            FriendsText.removeMessage,
            "They won't be told. Playlists you've shared stay shared until you stop sharing them.")
    }
}
