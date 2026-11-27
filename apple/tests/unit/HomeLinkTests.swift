import CryptoKit
import Foundation
import HTTPTypes
import RabbitEarsAPI
import XCTest

@testable import RabbitEarsKit

extension Fixtures {
    static let checkKey = Data(0..<32)
    /// The one address the faked server confirms at.
    static let lan = "http://10.0.0.2:8477"

    /// The proof either side owes for `nonce`, as server/internal/service/local.go computes it.
    static func proof(_ side: String, _ nonce: String) -> String {
        HMAC<SHA256>.authenticationCode(for: Data("\(side):\(nonce)".utf8), using: SymmetricKey(data: checkKey))
            .map { String(format: "%02x", $0) }.joined()
    }
}

extension RoutingTransport {
    /// The nonce of each confirmation sent to `Fixtures.lan`.
    func nonces() -> [String] {
        sent.filter { $0.baseURL.absoluteString == "\(Fixtures.lan)/api/v2" }.compactMap { sent in
            ((try? JSONSerialization.jsonObject(with: Data(sent.body.utf8))) as? [String: Any])?["nonce"] as? String
        }
    }

    /// Opens checks naming `addresses` and confirms at `Fixtures.lan` alone,
    /// answering what `reply` makes of the nonce; the real server answers its proof.
    func serveLocalChecks(
        addresses: [String] = ["http://192.168.7.7:8477", Fixtures.lan],
        reply: @escaping @Sendable (String) -> String = { Fixtures.proof("server", $0) }
    ) {
        let list = addresses.map { #""\#($0)""# }.joined(separator: ",")
        respond = { sent in
            if sent.path == "/local-checks" {
                return (
                    .created,
                    #"{"id":"c1","key":"\#(Fixtures.checkKey.base64EncodedString())","addresses":[\#(list)],"#
                        + #""expiresAt":"2026-01-01T00:01:00Z"}"#
                )
            }
            guard sent.path == "/local-checks/c1/confirmation", sent.baseURL.absoluteString == "\(Fixtures.lan)/api/v2"
            else { return nil }
            let body = (try? JSONSerialization.jsonObject(with: Data(sent.body.utf8))) as? [String: Any]
            return (.ok, #"{"proof":"\#(reply(body?["nonce"] as? String ?? ""))"}"#)
        }
    }
}

final class HomeLinkTests: XCTestCase {
    let server = ServerEndpoint(userInput: "https://media.example.test")!
    let stream = "/api/v2/streams/k/0/master.m3u8"
    var transport: RoutingTransport!

    override func setUp() {
        transport = RoutingTransport()
        transport.serveLocalChecks()
    }

    private func check(
        _ endpoint: ServerEndpoint? = nil, on path: PathFacts = PathFacts(), force: Bool = false, now: Date = Date()
    ) async {
        let endpoint = endpoint ?? server
        await endpoint.confirmHome(
            using: endpoint.client(token: "tok", transport: transport), on: path, force: force, transport: transport,
            now: now)
    }

    private var discoveredLocally: Bool {
        CapabilitySnapshotBuilder.network(PathFacts(), server: server, maxBitrate: nil).discoveredLocally
    }

    private var checks: Int { transport.paths(.post).filter { $0 == "/local-checks" }.count }

    func testTheFakedServerProvesAsTheRealOneDoes() {
        XCTAssertEqual(Fixtures.checkKey.base64EncodedString(), "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=")
        XCTAssertEqual(
            Fixtures.proof("client", "0123456789abcdef"),
            "4cb75bc399461f3f753c26613c4255dc32359753fb971f32dda89dad0b5fd00a")
        XCTAssertEqual(
            Fixtures.proof("server", "0123456789abcdef"),
            "07a81534f7cc202eb8ecf6676bae81d72c530387440efe1ec8f095e156985ed5")
    }

    func testAConfirmedCheckPutsAPublicEndpointAtHome() async throws {
        let copy = server
        XCTAssertFalse(server.atHome)
        XCTAssertFalse(discoveredLocally)
        await check()
        XCTAssertTrue(server.atHome)
        XCTAssertFalse(server.isLocalNetwork)
        XCTAssertTrue(copy.atHome, "every copy of the endpoint sees the check")
        XCTAssertEqual(server.home.localURL?.absoluteString, Fixtures.lan)
        XCTAssertTrue(discoveredLocally)
        XCTAssertEqual(server.resolveStream(stream).absoluteString, "\(Fixtures.lan)\(stream)")
        XCTAssertEqual(server.resolve(stream).absoluteString, "https://media.example.test\(stream)")

        let opened = try XCTUnwrap(transport.sent.first)
        XCTAssertEqual(opened.path, "/local-checks")
        XCTAssertEqual(opened.baseURL.absoluteString, "https://media.example.test/api/v2")
        XCTAssertEqual(opened.authorization, "Bearer tok")
        let confirmed = try XCTUnwrap(transport.sent.first { $0.baseURL.absoluteString == "\(Fixtures.lan)/api/v2" })
        XCTAssertEqual(confirmed.method, .post)
        XCTAssertEqual(confirmed.path, "/local-checks/c1/confirmation")
        XCTAssertNil(confirmed.authorization, "the token never crosses the local network")
        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(confirmed.body.utf8)) as? [String: String])
        let nonce = try XCTUnwrap(body["nonce"])
        XCTAssertTrue((16...64).contains(nonce.count), nonce)
        XCTAssertEqual(body["proof"], Fixtures.proof("client", nonce))
    }

    func testAReplyThatDoesNotProveTheKeyIsNotTrusted() async {
        let replies: [@Sendable (String) -> String] = [
            { Fixtures.proof("client", $0) },
            { String(Fixtures.proof("server", $0).dropLast(2)) },
            { _ in "not hex" },
        ]
        for reply in replies {
            transport.serveLocalChecks(reply: reply)
            await check(force: true)
            XCTAssertFalse(server.atHome)
            XCTAssertNil(server.home.localURL)
        }
        XCTAssertEqual(transport.nonces().count, replies.count, "each reply was asked for")
    }

    func testWithNoAddressAnsweringTheDeviceIsAway() async {
        transport.serveLocalChecks(addresses: ["http://192.168.7.7:8477", "not a url"])
        await check()
        XCTAssertFalse(server.atHome)

        transport.serveLocalChecks(addresses: [])
        await check()
        XCTAssertFalse(server.atHome)

        transport.respond = nil
        await check()
        XCTAssertFalse(server.atHome, "a server too old to open a check")
    }

    func testAnAddressThatNeverAnswersIsGivenUpOn() async {
        transport.hold = { sent in
            if sent.path.hasSuffix("/confirmation") { try await Task.sleep(for: .seconds(60)) }
        }
        let began = Date()
        await check()
        XCTAssertFalse(server.atHome)
        XCTAssertLessThan(Date().timeIntervalSince(began), 5)
    }

    func testOneAddressThatNeverAnswersDoesNotHoldUpAnother() async {
        transport.hold = { sent in
            if sent.baseURL.host() == "192.168.7.7" { try await Task.sleep(for: .seconds(60)) }
        }
        let began = Date()
        await check()
        XCTAssertTrue(server.atHome)
        XCTAssertLessThan(Date().timeIntervalSince(began), 1.5)
    }

    func testAFailedCheckLeavesHome() async {
        await check()
        XCTAssertTrue(server.atHome)
        transport.serveLocalChecks(addresses: ["http://192.168.7.7:8477"])
        await check(force: true)
        XCTAssertFalse(server.atHome)
        XCTAssertEqual(server.resolveStream(stream).absoluteString, "https://media.example.test\(stream)")
    }

    func testAStreamHasMovedOnceACheckFindsAnotherAddressThanItWasResolvedAt() async {
        await check()
        _ = server.resolveStream(stream)
        XCTAssertFalse(server.home.moved)
        transport.serveLocalChecks(addresses: [])
        await check(force: true)
        XCTAssertTrue(server.home.moved)
        _ = server.resolveStream(stream)
        XCTAssertFalse(server.home.moved)
    }

    func testACheckStandsTenMinutesOnItsPathUnlessForced() async {
        let began = Date()
        let cellular = PathFacts(expensive: true)
        await check(now: began)
        await check(now: began.addingTimeInterval(599))
        XCTAssertEqual(checks, 1)
        await check(on: cellular, now: began.addingTimeInterval(600))
        XCTAssertEqual(checks, 2, "a new path is when home is reached or left")
        await check(on: cellular, now: began.addingTimeInterval(1199))
        XCTAssertEqual(checks, 2)
        await check(on: cellular, now: began.addingTimeInterval(1201))
        XCTAssertEqual(checks, 3)
        await check(on: cellular, force: true, now: began.addingTimeInterval(1202))
        XCTAssertEqual(checks, 4)
        XCTAssertTrue(server.atHome)
        XCTAssertEqual(Set(transport.nonces()).count, 4, "a new nonce for each attempt")
    }

    func testACheckThatFoundNothingStandsAsLong() async {
        transport.serveLocalChecks(addresses: [])
        let began = Date()
        await check(now: began)
        await check(now: began.addingTimeInterval(599))
        XCTAssertEqual(checks, 1, "away from home a start waits on dead addresses once")
        await check(now: began.addingTimeInterval(601))
        XCTAssertEqual(checks, 2)
    }

    func testALocalEndpointAsksNothing() async {
        let local = ServerEndpoint(userInput: "192.168.1.9")!
        await check(local, force: true)
        XCTAssertTrue(transport.sent.isEmpty)
        XCTAssertTrue(local.atHome)
        XCTAssertNil(local.home.localURL)
        XCTAssertEqual(local.resolveStream(stream).absoluteString, "http://192.168.1.9:8477\(stream)")
    }

    func testEndpointsAreEqualByAddressWhateverTheirHome() async {
        let other = ServerEndpoint(userInput: "https://media.example.test")!
        await check()
        XCTAssertTrue(server.atHome)
        XCTAssertFalse(other.atHome)
        XCTAssertEqual(server, other)
        XCTAssertEqual(server.hashValue, other.hashValue)
        XCTAssertEqual(Set([server, other]).count, 1)
        XCTAssertNotEqual(server, ServerEndpoint(userInput: "https://other.example.test")!)
    }
}
