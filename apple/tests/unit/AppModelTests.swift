import Foundation
import RabbitEarsAPI
import Security
import XCTest

@testable import RabbitEarsKit

@MainActor
final class AppModelTests: XCTestCase {
    var store: MemoryCredentialStore!
    var transport: RoutingTransport!
    var model: AppModel!

    override func setUp() async throws {
        store = MemoryCredentialStore()
        transport = RoutingTransport([
            "POST /auth/sign-in": (.created, Fixtures.signedIn),
            "GET /me": (.ok, Fixtures.me),
            "POST /profiles/\(UID.n(1))/unlock": (.noContent, ""),
            "POST /profiles/\(UID.n(2))/unlock": (.noContent, ""),
        ])
        model = AppModel(
            store: store, deviceName: "Test Mac", transport: transport, replicaDirectory: Fixtures.replicas)
    }

    func testSignInStoresTheTokenAndServerThenAsksWhoIsWatching() async throws {
        try await model.signIn(server: "rabbit.local", email: "a@example.test", password: "secret")
        XCTAssertEqual(model.phase, .choosingProfile)
        XCTAssertEqual(store.token, "tok-1")
        XCTAssertEqual(store.server?.absoluteString, "http://rabbit.local:8477")
        XCTAssertEqual(model.profiles.map(\.name), ["Avery", "Robin"])
        XCTAssertEqual(model.householdName, "Avery")
        let body = try XCTUnwrap(transport.body(.post, "/auth/sign-in"))
        let request = Fixtures.decode(body, as: Components.Schemas.SignInRequest.self)
        XCTAssertEqual(request.platform, .macos)
        XCTAssertEqual(request.deviceName, "Test Mac")
    }

    func testWrongCredentialsAndBadServersSayWhy() async {
        transport.routes["POST /auth/sign-in"] = (.unauthorized, Fixtures.error("unauthorized"))
        await assertThrows(.wrongCredentials) {
            try await self.model.signIn(server: "rabbit.local", email: "a@example.test", password: "x")
        }
        await assertThrows(.badServer) { try await self.model.signIn(server: " ", email: "a", password: "x") }
        transport.failure = URLError(.cannotConnectToHost)
        await assertThrows(.unreachable) {
            try await self.model.signIn(server: "rabbit.local", email: "a@example.test", password: "x")
        }
        XCTAssertNotEqual(model.phase, .choosingProfile)
        XCTAssertNil(store.token)
    }

    func testTooManySignInsSayWhenToTryAgain() async {
        transport.routes["POST /auth/sign-in"] = (.tooManyRequests, Fixtures.error("too_many_requests"))
        transport.headers[.retryAfter] = "540"
        await assertThrows(.tooManyAttempts(minutes: 9)) {
            try await self.model.signIn(server: "rabbit.local", email: "a@example.test", password: "x")
        }
        XCTAssertEqual(
            AppError.tooManyAttempts(minutes: 9).localizedDescription, "Too many attempts. Try again in 9 minutes.")
        XCTAssertEqual(
            AppError.tooManyAttempts(minutes: 1).localizedDescription, "Too many attempts. Try again in 1 minute.")
        transport.headers[.retryAfter] = "30"
        await assertThrows(.tooManyAttempts(minutes: 1)) {
            try await self.model.signIn(server: "rabbit.local", email: "a@example.test", password: "x")
        }
    }

    func testPlainHTTPOutsideTheHomeNetworkAsksForHTTPSAndSendsNothing() async throws {
        let link = DeviceLink(id: 1, code: "7KQ4MN", link: "", expiresAt: Date(), pollToken: "p")
        for server in ["media.example.test", "http://media.example.test", "8.8.8.8:8477", "[2001:db8::1]"] {
            await assertThrows(.insecureServer) {
                try await self.model.signIn(server: server, email: "a@example.test", password: "x")
            }
            await assertThrows(.insecureServer) {
                _ = try await self.model.joinPreview(server: server, code: "7KQ4-MNP2")
            }
            await assertThrows(.insecureServer) {
                try await self.model.acceptJoin(server: server, code: "7KQ4-MNP2", name: "A", password: "p")
            }
            await assertThrows(.insecureServer) {
                _ = try await self.model.requestLink(server: XCTUnwrap(ServerEndpoint(userInput: server)))
            }
            await assertThrows(.insecureServer) {
                _ = try await self.model.pollLink(link, server: XCTUnwrap(ServerEndpoint(userInput: server)))
            }
        }
        XCTAssertTrue(transport.sent.isEmpty)
        XCTAssertNil(store.server)
        XCTAssertEqual(
            AppError.insecureServer.localizedDescription, "Use https:// for a server outside your home network.")
        XCTAssertEqual(AppError.from(URLError(.appTransportSecurityRequiresSecureConnection)), .insecureServer)

        try await model.signIn(server: "https://media.example.test", email: "a@example.test", password: "x")
        XCTAssertEqual(store.server?.absoluteString, "https://media.example.test")
        try await model.signIn(server: "192.168.1.9", email: "a@example.test", password: "x")
        XCTAssertEqual(store.server?.absoluteString, "http://192.168.1.9:8477")
    }

    func testRestoreReusesTheStoredToken() async {
        store.server = URL(string: "https://media.example.test:8477")
        store.token = "old"
        await model.restore()
        XCTAssertEqual(model.phase, .choosingProfile)
        XCTAssertEqual(transport.sent.first?.authorization, "Bearer old")
    }

    func testRestoreSendsNoTokenOverPlainHTTPOutsideTheHomeNetwork() async {
        store.server = URL(string: "http://media.example.test:8477")
        store.token = "old"
        await model.restore()
        XCTAssertEqual(model.phase, .signedOut)
        XCTAssertTrue(transport.sent.isEmpty)
        XCTAssertEqual(model.lastServer, "http://media.example.test:8477")
    }

    func testRestoreWithARevokedTokenSignsOut() async {
        store.server = URL(string: "https://media.example.test:8477")
        store.token = "old"
        transport.routes["GET /me"] = (.unauthorized, Fixtures.error("unauthorized"))
        await model.restore()
        XCTAssertEqual(model.phase, .signedOut)
        XCTAssertNil(store.token)
        XCTAssertEqual(model.lastServer, "https://media.example.test:8477")
    }

    func testRestoreWithTheServerUnreachableKeepsTheTokenAndTriesAgain() async {
        store.server = URL(string: "https://media.example.test:8477")
        store.token = "old"
        transport.failure = URLError(.cannotConnectToHost)
        await model.restore()
        XCTAssertEqual(model.phase, .unreachable)
        XCTAssertEqual(store.token, "old")
        transport.failure = nil
        await model.restore()
        XCTAssertEqual(model.phase, .choosingProfile)
    }

    func testRestoreWithAServerErrorKeepsTheToken() async {
        store.server = URL(string: "https://media.example.test:8477")
        store.token = "old"
        transport.routes["GET /me"] = (.internalServerError, Fixtures.error("internal"))
        await model.restore()
        XCTAssertEqual(model.phase, .unreachable)
        XCTAssertEqual(store.token, "old")
    }

    func testChoosingAProfileUnlocksItWithThePin() async throws {
        try await model.signIn(server: "rabbit.local", email: "a@example.test", password: "x")
        let kid = try XCTUnwrap(model.profiles.last)
        try await model.choose(kid, pin: "1234")
        XCTAssertEqual(model.phase, .browsing)
        XCTAssertEqual(model.activeProfile?.id, 2)
        XCTAssertEqual(transport.json(.post, "/profiles/\(UID.n(2))/unlock")?["pin"] as? String, "1234")
    }

    /// What one profile may not see the next may: art missing for a kid is asked for again as an adult.
    func testSwitchingProfilesAsksAgainForArtThatWasMissing() async throws {
        try await model.signIn(server: "rabbit.local", email: "a@example.test", password: "x")
        let avery = try XCTUnwrap(model.profiles.first)
        let kid = try XCTUnwrap(model.profiles.last)
        try await model.choose(kid, pin: "1234")
        let art = try XCTUnwrap(model.artwork)
        let asked = { self.transport.paths(.get).filter { $0 == "/items/\(UID.n(7))/artwork/poster" }.count }
        _ = await art.data(7, .poster)
        _ = await art.data(7, .poster)
        XCTAssertEqual(asked(), 1)
        try await model.choose(avery)
        _ = await art.data(7, .poster)
        XCTAssertEqual(asked(), 2)
    }

    func testPinErrorsMapToTheirMessages() async throws {
        try await model.signIn(server: "rabbit.local", email: "a@example.test", password: "x")
        let kid = try XCTUnwrap(model.profiles.last)
        transport.routes["POST /profiles/\(UID.n(2))/unlock"] = (.forbidden, Fixtures.error("forbidden"))
        await assertThrows(.wrongPin) { try await self.model.choose(kid, pin: "0000") }
        transport.routes["POST /profiles/\(UID.n(2))/unlock"] = (.forbidden, Fixtures.error("pin_locked"))
        await assertThrows(.pinLocked) { try await self.model.choose(kid, pin: "0000") }
        XCTAssertEqual(model.phase, .choosingProfile)
    }

    func testAcceptJoinConsumesTheCode() async throws {
        transport.routes["POST /join/7KQ4-MNP2"] = (.created, Fixtures.signedIn)
        try await model.acceptJoin(
            server: "rabbit.local", code: "7kq4mnp2", name: "Avery", password: "long password")
        XCTAssertEqual(model.phase, .choosingProfile)
        XCTAssertEqual(store.token, "tok-1")
    }

    func testAcceptingAUsedCodeSaysItIsNoLongerValid() async {
        transport.routes["POST /join/7KQ4-MNP2"] = (.notFound, Fixtures.error("not_found", "join code"))
        await assertThrows(.inviteInvalid) {
            try await self.model.acceptJoin(server: "rabbit.local", code: "7KQ4-MNP2", name: "A", password: "p")
        }
    }

    func testAnUnknownJoinCodeIsNoLongerValid() async {
        await assertThrows(.inviteInvalid) {
            _ = try await self.model.joinPreview(server: "rabbit.local", code: "7KQ4-MNP2")
        }
        await assertThrows(.inviteInvalid) {
            _ = try await self.model.joinPreview(server: "rabbit.local", code: "nope")
        }
    }

    func testChangingThePasswordSendsBothAndSaysWhenTheCurrentIsWrong() async throws {
        try await model.signIn(server: "rabbit.local", email: "a@example.test", password: "x")
        transport.routes["PUT /me/password"] = (.forbidden, Fixtures.error("forbidden"))
        await assertThrows(.wrongPassword) {
            try await self.model.changePassword(current: "nope", new: "a much better one")
        }
        transport.routes["PUT /me/password"] = (.noContent, "")
        try await model.changePassword(current: "old password", new: "a much better one")
        let sent = transport.json(.put, "/me/password")
        XCTAssertEqual(sent?["currentPassword"] as? String, "old password")
        XCTAssertEqual(sent?["newPassword"] as? String, "a much better one")
    }

    func testTheOwnerAddsAnAdultAndGetsTheCodeToHandOver() async throws {
        let bea = Fixtures.account(3, "Bea").replacingOccurrences(of: #""pending":false"#, with: #""pending":true"#)
        let code =
            #"{"id":"\#(UID.n(1))","code":"7KQ4-MNP2","link":"/join/7KQ4-MNP2","accountId":"\#(UID.n(3))","#
            + #""expiresAt":"2026-01-08T00:00:00Z","createdAt":"2026-01-01T00:00:00.5Z","#
            + #""modifiedAt":"2026-01-01T00:00:00.5Z"}"#
        transport.routes["POST /household/adults"] = (.created, #"{"account":\#(bea),"joinCode":\#(code)}"#)
        try await model.signIn(server: "rabbit.local", email: "a@example.test", password: "x")
        XCTAssertTrue(model.isOwner)
        let invite = try await model.addAdult(name: "Bea", email: "bea@example.test")
        XCTAssertEqual(invite.code, "7KQ4-MNP2")
        XCTAssertEqual(invite.url.absoluteString, "http://rabbit.local:8477/join/7KQ4-MNP2")
        let sent = transport.json(.post, "/household/adults")
        XCTAssertEqual(sent?["name"] as? String, "Bea")
        XCTAssertEqual(sent?["email"] as? String, "bea@example.test")
        transport.routes["POST /household/adults"] = (.conflict, Fixtures.error("conflict"))
        await assertThrows(.emailTaken) { _ = try await self.model.addAdult(name: "Bea", email: "bea@example.test") }
    }

    func testInvitedAdultsAreNotChoosableAndOnlyTheOwnerAddsAdults() async throws {
        let pending = Fixtures.account(3, "Cy").replacingOccurrences(of: #""pending":false"#, with: #""pending":true"#)
        let other = Fixtures.me.replacingOccurrences(
            of: #""activeProfileId":"\#(UID.n(1))""#, with: #""activeProfileId":"\#(UID.n(4))""#
        ).replacingOccurrences(
            of: #"\#(Fixtures.kid)]"#, with: #"\#(Fixtures.kid),\#(pending),\#(Fixtures.account(4, "Bea"))]"#)
        transport.routes["POST /auth/sign-in"] = (.created, #"{"token":"tok-1","me":\#(other)}"#)
        try await model.signIn(server: "rabbit.local", email: "a@example.test", password: "x")
        XCTAssertEqual(model.profiles.map(\.name), ["Avery", "Robin", "Bea"])
        XCTAssertFalse(model.isOwner)
    }

    func testAddingAKidWithAPinSetsItAfterCreating() async throws {
        transport.routes["POST /profiles"] = (.created, Fixtures.account(3, "Sam", kind: "kid"))
        transport.routes["PUT /profiles/\(UID.n(3))/pin"] = (.noContent, "")
        try await model.signIn(server: "rabbit.local", email: "a@example.test", password: "x")
        var form = AddKidForm(today: Date(timeIntervalSince1970: 1_780_000_000))
        form.name = "Sam"
        form.requirePin = true
        form.pin = "4321"
        form.pinConfirmation = "4321"
        try await model.addKid(form) { form.editing = $0 }
        XCTAssertEqual(transport.paths(.post).filter { $0 == "/profiles" }.count, 1)
        XCTAssertEqual(transport.json(.put, "/profiles/\(UID.n(3))/pin")?["pin"] as? String, "4321")
        XCTAssertEqual(transport.paths(.get).filter { $0 == "/me" }.count, 1)
    }

    func testAPinThatFailsAfterTheKidIsCreatedIsRetriedOnThatKid() async throws {
        transport.routes["POST /profiles"] = (.created, Fixtures.account(3, "Sam", kind: "kid"))
        transport.routes["PUT /profiles/\(UID.n(3))"] = (.ok, Fixtures.account(3, "Sammy", kind: "kid"))
        transport.routes["PUT /profiles/\(UID.n(3))/pin"] = (.internalServerError, Fixtures.error("internal"))
        try await model.signIn(server: "rabbit.local", email: "a@example.test", password: "x")
        var form = AddKidForm(today: Date(timeIntervalSince1970: 1_780_000_000))
        form.name = "Sam"
        form.requirePin = true
        form.pin = "4321"
        form.pinConfirmation = "4321"
        await assertThrows(.server("nope")) { try await self.model.addKid(form) { form.editing = $0 } }

        transport.routes["PUT /profiles/\(UID.n(3))/pin"] = (.noContent, "")
        form.name = "Sammy"
        try await model.addKid(form) { form.editing = $0 }
        XCTAssertEqual(transport.paths(.post).filter { $0 == "/profiles" }.count, 1)
        XCTAssertEqual(transport.json(.put, "/profiles/\(UID.n(3))")?["name"] as? String, "Sammy")
        XCTAssertEqual(transport.json(.put, "/profiles/\(UID.n(3))/pin")?["pin"] as? String, "4321")
        XCTAssertEqual(form.submitTitle, "Save")
    }

    func testSignOutForgetsTheTokenButKeepsTheServer() async throws {
        transport.routes["POST /auth/sign-out"] = (.noContent, "")
        try await model.signIn(server: "rabbit.local", email: "a@example.test", password: "x")
        await model.signOut()
        // The name asked of the server after sign-in may be answered after this.
        XCTAssertEqual(transport.sent.last { $0.path == "/auth/sign-out" }?.authorization, "Bearer tok-1")
        XCTAssertEqual(model.phase, .signedOut)
        XCTAssertNil(store.token)
        XCTAssertNotNil(store.server)
    }

    func testOnlyKidsOnAnAllowListAreOfferedPerTitle() async throws {
        let listed = Fixtures.account(3, "Sam", kind: "kid").replacingOccurrences(
            of: #""ratings""#, with: #""allow_list""#)
        try await model.signIn(server: "rabbit.local", email: "a@example.test", password: "x")
        XCTAssertEqual(model.allowListKids.map(\.id), [])
        transport.routes["GET /me"] = (
            .ok, Fixtures.me.replacingOccurrences(of: "\(Fixtures.kid)]", with: "\(Fixtures.kid),\(listed)]")
        )
        await model.reload()
        XCTAssertEqual(model.allowListKids.map(\.id), [3])
    }

    private func assertThrows(
        _ expected: AppError, _ body: () async throws -> Void, line: UInt = #line
    ) async {
        do {
            try await body()
            XCTFail("expected \(expected)", line: line)
        } catch {
            XCTAssertEqual(error as? AppError, expected, line: line)
        }
    }
}

final class KeychainCredentialStoreTests: XCTestCase {
    func testTheTokenStaysOnThisDeviceAndIsReadableAfterFirstUnlock() {
        let item = KeychainCredentialStore().newItem("tok-1")
        XCTAssertEqual(
            item[kSecAttrAccessible as String] as? String, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        XCTAssertEqual(item[kSecValueData as String] as? Data, Data("tok-1".utf8))
    }

    func testProfileMemoryOutlivesTheStoreThatWroteIt() throws {
        let suite = "profile-memory-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let memory = ProfileMemory(remember: true, skipPin: false, lastProfileId: 2)
        KeychainCredentialStore(defaults: defaults).profileMemories["a 1"] = memory
        XCTAssertEqual(KeychainCredentialStore(defaults: defaults).profileMemories, ["a 1": memory])
    }

    func testProfileMemoryKeptWithANumericIdIsForgottenNotACrash() throws {
        let suite = "profile-memory-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(
            Data(#"{"a 1":{"remember":true,"skipPin":true,"lastProfileId":2}}"#.utf8), forKey: "profileMemories")
        XCTAssertEqual(KeychainCredentialStore(defaults: defaults).profileMemories, [:])
    }
}

extension AppModelTests {
    func testSigningOutOrARevokedTokenLeavesNoReplicaOrCachedResponse() async throws {
        let directory = Fixtures.replicas
        defer { try? FileManager.default.removeItem(at: directory) }
        model = AppModel(store: store, deviceName: "Test Mac", transport: transport, replicaDirectory: directory)
        let request = URLRequest(url: URL(string: "http://rabbit.local:8477/api/v2/items/\(UID.n(20))/artwork/poster")!)
        func keep() throws {
            XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)), "opened")
            let response = try XCTUnwrap(
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil))
            // In memory only: a disk write lands at a time of its own, maybe after the clear.
            URLCache.shared.storeCachedResponse(
                CachedURLResponse(
                    response: response, data: Data("jpeg".utf8), userInfo: nil, storagePolicy: .allowedInMemoryOnly),
                for: request)
        }
        func forgotten() -> Bool {
            !FileManager.default.fileExists(atPath: directory.path(percentEncoded: false))
                && URLCache.shared.cachedResponse(for: request) == nil
        }

        transport.routes["POST /auth/sign-out"] = (.noContent, "")
        try await model.signIn(server: "rabbit.local", email: "a@example.test", password: "x")
        try keep()
        await model.signOut()
        XCTAssertTrue(forgotten())

        store.token = "old"
        transport.routes["GET /me"] = (.unauthorized, Fixtures.error("unauthorized"))
        await model.restore()
        XCTAssertEqual(model.phase, .signedOut)
        for _ in 0..<300 where !forgotten() { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(forgotten())
    }
}
