import Foundation
import HTTPTypes
import XCTest

@testable import RabbitEarsKit

@MainActor
final class ServerNameTests: XCTestCase {
    var store: MemoryCredentialStore!
    var transport: RoutingTransport!
    var model: AppModel!

    override func setUp() async throws {
        store = MemoryCredentialStore()
        transport = RoutingTransport([
            "POST /auth/sign-in": (.created, Fixtures.signedIn),
            "GET /me": (.ok, Fixtures.me),
            "GET /health": (.ok, Self.health("The Den")),
        ])
        model = AppModel(
            store: store, deviceName: "Test Mac", transport: transport, replicaDirectory: Fixtures.replicas)
    }

    static func health(_ name: String?) -> String {
        let field = name.map { #","serverName":"\#($0)""# } ?? ""
        return #"{"status":"ok","version":"1.0.0","setupRequired":false\#(field)}"#
    }

    /// Waits for the name the kit asks for on its own task.
    private func until(_ done: () -> Bool) async {
        for _ in 0..<200 where !done() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    func testBeforeAServerIsKnownTheProductNameShows() {
        XCTAssertEqual(model.serverName, "Rabbit Ears")
        XCTAssertEqual(model.serverName(at: ""), "Rabbit Ears")
        XCTAssertEqual(model.serverName(at: "rabbit.local"), "Rabbit Ears")
    }

    func testSigningInLearnsAndKeepsTheServersName() async throws {
        try await model.signIn(server: "rabbit.local", email: "a@example.test", password: "x")
        await until { model.serverName == "The Den" }
        XCTAssertEqual(model.serverName, "The Den")
        XCTAssertEqual(model.serverName(at: "rabbit.local"), "The Den")
        XCTAssertEqual(model.serverName(at: "other.local"), "Rabbit Ears")
        XCTAssertEqual(store.serverName, "The Den")
    }

    func testALaunchShowsTheStoredNameBeforeAndWithoutTheServer() async {
        store.server = URL(string: "http://rabbit.local:8477")
        store.token = "tok-1"
        store.serverName = "The Den"
        transport.failure = URLError(.cannotConnectToHost)
        model = AppModel(
            store: store, deviceName: "Test Mac", transport: transport, replicaDirectory: Fixtures.replicas)
        XCTAssertEqual(model.serverName, "The Den")
        await model.restore()
        XCTAssertEqual(model.phase, .unreachable)
        XCTAssertEqual(model.serverName, "The Den")
    }

    func testALaunchRefreshesARenamedServer() async {
        store.server = URL(string: "http://rabbit.local:8477")
        store.token = "tok-1"
        store.serverName = "The Den"
        transport.routes["GET /health"] = (.ok, Self.health("Cabin"))
        model = AppModel(
            store: store, deviceName: "Test Mac", transport: transport, replicaDirectory: Fixtures.replicas)
        await model.restore()
        await until { model.serverName == "Cabin" }
        XCTAssertEqual(model.serverName, "Cabin")
        XCTAssertEqual(store.serverName, "Cabin")
    }

    func testANamelessOrSilentAnswerKeepsTheKnownName() async throws {
        store.server = URL(string: "http://rabbit.local:8477")
        store.serverName = "The Den"
        let answers: [(HTTPResponse.Status, String)] = [
            (.ok, Self.health(nil)), (.ok, Self.health("  ")), (.internalServerError, ""),
        ]
        for answer in answers {
            transport.routes["GET /health"] = answer
            try await model.signIn(server: "rabbit.local", email: "a@example.test", password: "x")
            await until { transport.paths(.get).contains("/health") }
            await model.learnName(ServerEndpoint(userInput: "rabbit.local")!)
            XCTAssertEqual(model.serverName, "The Den")
            XCTAssertEqual(store.serverName, "The Den")
        }
    }

    func testSigningInElsewhereReplacesTheName() async throws {
        store.server = URL(string: "http://old.local:8477")
        store.serverName = "Old Place"
        transport.routes["GET /health"] = (.internalServerError, "")
        try await model.signIn(server: "rabbit.local", email: "a@example.test", password: "x")
        XCTAssertEqual(model.serverName, "Rabbit Ears")
        XCTAssertNil(store.serverName)
    }

    func testSigningOutKeepsTheAddressAndItsName() async throws {
        transport.routes["POST /auth/sign-out"] = (.noContent, "")
        try await model.signIn(server: "rabbit.local", email: "a@example.test", password: "x")
        await until { model.serverName == "The Den" }
        await model.signOut()
        XCTAssertEqual(model.serverName, "The Den")
        XCTAssertEqual(model.serverName(at: model.lastServer), "The Den")
    }

    func testAServerChosenBeforeSignInIsNamedWithoutBeingStored() async {
        let other = ServerEndpoint(userInput: "other.local")!
        await model.learnName(other)
        XCTAssertEqual(model.serverName(at: "other.local"), "The Den")
        XCTAssertEqual(model.serverName(at: other), "The Den")
        XCTAssertEqual(model.serverName, "Rabbit Ears")
        XCTAssertNil(store.serverName)
    }

    func testAnInvitesServerIsNamedOnceItsInviteIsRead() async throws {
        transport.routes["GET /join/7KQ4-MNP2"] =
            (.ok, #"{"name":"Sam","invitedBy":"Avery","expiresAt":"2026-01-01T00:00:00Z"}"#)
        _ = try await model.joinPreview(server: "rabbit.local", code: "7KQ4-MNP2")
        await until { model.serverName(at: "rabbit.local") == "The Den" }
        XCTAssertEqual(model.serverName(at: "rabbit.local"), "The Den")
    }

    func testTheNameOutlivesTheStoreThatWroteIt() throws {
        let suite = "server-name-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        KeychainCredentialStore(defaults: defaults).serverName = "The Den"
        XCTAssertEqual(KeychainCredentialStore(defaults: defaults).serverName, "The Den")
    }
}
