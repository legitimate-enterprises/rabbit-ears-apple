import Foundation
import HTTPTypes
import RabbitEarsAPI
import XCTest

@testable import RabbitEarsKit

@MainActor
final class AccountDeletionTests: XCTestCase {
    var store: MemoryCredentialStore!
    var transport: RoutingTransport!
    var model: AppModel!

    override func setUp() async throws {
        store = MemoryCredentialStore()
        transport = RoutingTransport([
            "POST /auth/sign-in": (.created, Fixtures.signedIn),
            "GET /me": (.ok, Fixtures.me),
            "GET /me/deletion": (.ok, #"{"outcome":"transfer","newOwnerName":"Bea","kidNames":[]}"#),
        ])
        model = AppModel(
            store: store, deviceName: "Test Mac", transport: transport, replicaDirectory: Fixtures.replicas)
        try await model.signIn(server: "rabbit.local", email: "a@example.test", password: "x")
    }

    private func deletion(_ json: String) -> AccountDeletion { Fixtures.decode(json, as: AccountDeletion.self) }

    func testTheConfirmationSaysWhichWayTheHouseholdGoes() async throws {
        let told = try await model.accountDeletion()
        XCTAssertTrue(told.allowed)
        XCTAssertTrue(
            told.summary.hasSuffix("cannot be undone. The household stays, with its kids, and Bea becomes its owner."))
        XCTAssertTrue(
            deletion(#"{"outcome":"account","kidNames":[]}"#).summary.hasSuffix("The household stays as it is."))
        XCTAssertTrue(
            deletion(#"{"outcome":"household","kidNames":[]}"#).summary.hasSuffix("so the household goes too."))
        XCTAssertTrue(
            deletion(#"{"outcome":"household","kidNames":["Mia","Leo","Ada"]}"#).summary
                .hasSuffix("the household goes too, with Mia, Leo and Ada and everything of theirs."))
        let refused = deletion(#"{"outcome":"refused","kidNames":[]}"#)
        XCTAssertFalse(refused.allowed)
        XCTAssertTrue(refused.summary.contains("make another account an admin"))
        XCTAssertFalse(refused.summary.contains("cannot be undone"))
    }

    func testDeletingSendsThePasswordThenSignsThisDeviceOut() async throws {
        transport.routes["POST /me/deletion"] = (.forbidden, Fixtures.error("forbidden"))
        do {
            try await model.deleteAccount(password: "nope")
            XCTFail("deleted with a wrong password")
        } catch {
            XCTAssertEqual(error as? AppError, .wrongPassword)
        }
        XCTAssertEqual(store.token, "tok-1")

        transport.routes["POST /me/deletion"] = (.noContent, "")
        try await model.deleteAccount(password: "the password")
        XCTAssertEqual(transport.json(.post, "/me/deletion")?["password"] as? String, "the password")
        XCTAssertEqual(model.phase, .signedOut)
        XCTAssertNil(store.token)
    }

    /// Another device of an account deleted here hears 401 on its held poll and signs out.
    func testAFollowerTheServerNoLongerKnowsSignsOut() async throws {
        let client = ServerEndpoint(userInput: "192.168.1.9")!.client(token: "t", transport: transport)
        for (status, code, gone) in [
            (HTTPResponse.Status.unauthorized, "unauthorized", true), (.forbidden, "device_locked", false),
            (.notFound, "not_found", false),
        ] {
            transport.routes["GET /events"] = (status, Fixtures.error(code))
            let signedOut = await LiveFeed().follow(client) { _ in }
            XCTAssertEqual(signedOut, gone, code)
        }
    }

    /// A proxy or auth layer in front of the server may answer 401 with a body of its own.
    func testAFollowerHearingA401TheServerDidNotSendStaysSignedIn() async throws {
        let client = ServerEndpoint(userInput: "192.168.1.9")!.client(token: "t", transport: transport)
        transport.routes["GET /events"] = (.unauthorized, "<html>401 Authorization Required</html>")
        let signedOut = await LiveFeed().follow(client) { _ in }
        XCTAssertFalse(signedOut)
    }
}
