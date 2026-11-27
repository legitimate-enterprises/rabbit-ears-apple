import Foundation
import HTTPTypes
import RabbitEarsAPI
import XCTest

@testable import RabbitEarsKit

@MainActor
final class DeviceLinkModelTests: XCTestCase {
    let server = ServerEndpoint(userInput: "rabbit.local")!

    static let created =
        #"{"id":"\#(UID.n(5))","code":"7KQ4-MNP2","link":"/link?code=7KQ4-MNP2","expiresAt":"2026-01-01T00:10:00Z","#
        + #""pollToken":"poll-secret"}"#

    static func poll(_ status: String, signIn: Bool = false) -> String {
        let handover = signIn ? #","signIn":\#(Fixtures.signedIn)"# : ""
        return #"{"status":"\#(status)","expiresAt":"2026-01-01T00:10:00Z"\#(handover)}"#
    }

    /// Answers the polls in order, then keeps answering the last.
    func transport(_ polls: [(HTTPResponse.Status, String)]) -> RoutingTransport {
        let transport = RoutingTransport(["POST /device-links": (.created, Self.created)])
        var remaining = polls
        transport.respond = { sent in
            guard sent.method == .get, sent.path == "/device-links/\(UID.n(5))" else { return nil }
            return remaining.count > 1 ? remaining.removeFirst() : remaining[0]
        }
        return transport
    }

    func model(_ transport: RoutingTransport, store: CredentialStore = MemoryCredentialStore()) -> (
        AppModel, DeviceLinkModel
    ) {
        let app = AppModel(
            store: store, deviceName: "Living Room", platform: .tvos, transport: transport,
            replicaDirectory: Fixtures.replicas)
        return (app, DeviceLinkModel(app: app, server: server, interval: .zero))
    }

    func testAnApprovedCodeSignsThisAppleTVIn() async throws {
        let transport = transport([(.ok, Self.poll("pending")), (.ok, Self.poll("approved", signIn: true))])
        let store = MemoryCredentialStore()
        let (app, link) = model(transport, store: store)
        await link.run()
        XCTAssertEqual(app.phase, .choosingProfile)
        XCTAssertEqual(store.token, "tok-1")
        XCTAssertEqual(store.server, server.baseURL)
        XCTAssertEqual(link.link?.code, "7KQ4-MNP2")
        let input = try XCTUnwrap(transport.body(.post, "/device-links"))
        let request = Fixtures.decode(input, as: Components.Schemas.DeviceLinkInput.self)
        XCTAssertEqual(request.platform, .tvos)
        XCTAssertEqual(request.deviceName, "Living Room")
        XCTAssertEqual(
            transport.queries(.get, "/device-links/\(UID.n(5))"), ["token=poll-secret", "token=poll-secret"])
    }

    func testADeniedCodeSaysSo() async {
        let (app, link) = model(transport([(.ok, Self.poll("denied"))]))
        await link.run()
        XCTAssertEqual(link.state, .denied)
        XCTAssertEqual(app.phase, .starting)
    }

    /// A 404 is the answer for a code that ran out or was handed over already.
    func testAnUnknownCodeReadsAsExpired() async {
        let (_, link) = model(transport([(.notFound, Fixtures.error("not_found"))]))
        await link.run()
        XCTAssertEqual(link.state, .expired)
    }

    func testAServerErrorKeepsWaiting() async {
        let transport = transport([
            (.internalServerError, Fixtures.error("internal")), (.ok, Self.poll("pending")),
            (.ok, Self.poll("expired")),
        ])
        let (_, link) = model(transport)
        await link.run()
        XCTAssertEqual(link.state, .expired)
        XCTAssertEqual(transport.paths(.get).filter { $0 == "/device-links/\(UID.n(5))" }.count, 3)
    }

    func testTheServerGivingACodeIsNamedBeforeSignIn() async {
        let transport = transport([(.ok, Self.poll("expired"))])
        transport.routes["GET /health"] =
            (.ok, #"{"status":"ok","version":"1.0.0","setupRequired":false,"serverName":"The Den"}"#)
        let (app, link) = model(transport)
        await link.run()
        for _ in 0..<200 where app.serverName(at: server) != "The Den" { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(app.serverName(at: server), "The Den")
        XCTAssertEqual(app.serverName, "Rabbit Ears")
    }

    func testARefusedCodeRequestShowsWhy() async {
        let transport = RoutingTransport([
            "POST /device-links": (.tooManyRequests, Fixtures.error("too_many_requests", "slow down"))
        ])
        let (_, link) = model(transport)
        await link.run()
        XCTAssertEqual(link.state, .failed("Too many attempts. Try again in 1 minute."))
        XCTAssertNil(link.link)
    }

    func testTheCodeNamesWhereToTypeItAndTheQRImage() async {
        let (_, link) = model(transport([(.ok, Self.poll("denied"))]))
        XCTAssertNil(link.qrURL)
        await link.run()
        XCTAssertEqual(link.address, "rabbit.local:8477/link")
        XCTAssertEqual(
            link.qrURL?.absoluteString, "http://rabbit.local:8477/api/v2/device-links/\(UID.n(5))/qr?token=poll-secret")
        let expires = ISO8601DateFormatter().date(from: "2026-01-01T00:10:00Z")!
        XCTAssertEqual(link.countdown(at: expires.addingTimeInterval(-581)), "9:41")
        XCTAssertNil(link.countdown(at: expires))
    }
}
