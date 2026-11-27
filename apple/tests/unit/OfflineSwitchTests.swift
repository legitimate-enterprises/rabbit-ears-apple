import Foundation
import RabbitEarsAPI
import XCTest

@testable import RabbitEarsKit

/// A device in use switches offline only to a profile the replica says has no PIN.
@MainActor
final class OfflineSwitchTests: XCTestCase {
    static let sam = Fixtures.account(3, "Sam", kind: "kid")
    static let me = Fixtures.me.replacingOccurrences(of: "\(Fixtures.kid)]", with: "\(Fixtures.kid),\(sam)]")
    var app: SyncedApp!

    override func setUp() async throws {
        app = try SyncedApp(signIn: #"{"token":"tok-1","me":\#(Self.me)}"#) { db in
            try db.member(1, "Avery")
            try db.member(2, "Robin", kind: "kid", pin: true)
            try db.member(3, "Sam", kind: "kid")
        }
        app.routes.routes["GET /me"] = (.ok, Self.me)
        app.routes.routes["POST /profiles/\(UID.n(2))/unlock"] = (.noContent, "")
        app.routes.routes["POST /profiles/\(UID.n(3))/unlock"] = (.noContent, "")
        _ = try await app.synced()
    }

    override func tearDown() { app.remove() }

    private func profile(_ id: UID) throws -> Account { try XCTUnwrap(app.model.profiles.first { $0.id == id }) }

    func testOfflineAProfileWithoutAPinIsSwitchedToHereAlone() async throws {
        app.offline()
        try await app.model.choose(profile(3))
        XCTAssertEqual(app.model.phase, .browsing)
        XCTAssertEqual(app.model.activeProfile?.id, 3)
        XCTAssertEqual(app.model.serverActiveProfile?.id, 3, "household writes act as it")
        XCTAssertFalse(app.model.locked)

        let next = app.relaunch()
        await next.restore()
        XCTAssertEqual(next.phase, .browsing, "the next launch offline continues as it")
        XCTAssertEqual(next.activeProfile?.id, 3)
    }

    func testOfflineAProfileWithAPinIsRefusedAsBefore() async throws {
        app.offline()
        do {
            try await app.model.choose(profile(2), pin: "1234")
            XCTFail("unlocked a PIN profile offline")
        } catch {
            XCTAssertEqual(error as? AppError, .unreachable)
        }
        XCTAssertEqual(app.model.phase, .choosingProfile)
        XCTAssertNil(app.model.activeProfile)
    }

    func testOnlineAPickIsTheServersAsBefore() async throws {
        try await app.model.choose(profile(3))
        XCTAssertEqual(app.routes.paths(.post).filter { $0.hasSuffix("/unlock") }, ["/profiles/\(UID.n(3))/unlock"])
        XCTAssertEqual(app.model.activeProfile?.id, 3)
    }

    func testBackOnlineTheServerIsToldTheProfileSwitchedToOffline() async throws {
        app.offline()
        try await app.model.choose(profile(3))
        app.routes.failure = nil
        await app.model.reload()
        XCTAssertEqual(app.routes.paths(.post).filter { $0.hasSuffix("/unlock") }, ["/profiles/\(UID.n(3))/unlock"])
        XCTAssertEqual(app.model.serverActiveProfile?.id, 3)
        XCTAssertEqual(app.model.phase, .browsing)
    }
}
