import Foundation
import HTTPTypes
import OpenAPIRuntime
import RabbitEarsAPI
import XCTest

@testable import RabbitEarsKit

/// Records each request and answers with a canned JSON body.
final class RecordingTransport: ClientTransport, @unchecked Sendable {
    struct Sent {
        let request: HTTPRequest
        let baseURL: URL
        let body: String
    }

    var requests: [Sent] = []
    let status: HTTPResponse.Status
    let body: String

    init(status: HTTPResponse.Status = .ok, body: String) {
        self.status = status
        self.body = body
    }

    func send(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String
    ) async throws -> (HTTPResponse, HTTPBody?) {
        var sent = ""
        if let body { sent = try await String(collecting: body, upTo: 1 << 20) }
        requests.append(Sent(request: request, baseURL: baseURL, body: sent))
        var response = HTTPResponse(status: status)
        response.headerFields[.contentType] = "application/json"
        return (response, HTTPBody(self.body))
    }
}

final class APIClientTests: XCTestCase {
    func testAStalledAnswerFailsInHalfAMinuteAndArtworkStaysInTheAppsCache() {
        XCTAssertEqual(Client.session.configuration.timeoutIntervalForRequest, 30)
        XCTAssertTrue(Client.session.configuration.urlCache === URLCache.shared)
    }

    func testListsLibrariesWithTheDeviceToken() async throws {
        let transport = RecordingTransport(
            body:
                #"{"items":[{"id":"\#(UID.n(1))","name":"Films","kind":"movies","scanHour":3,"watchFiles":true,"#
                + #""folders":[],"#
                + #""stats":{"movies":0,"shows":0,"seasons":0,"episodes":0,"files":0,"bytes":0,"unmatched":0},"#
                + #""createdAt":"2026-01-01T00:00:00Z","modifiedAt":"2026-01-01T00:00:00Z"}],"nextOffset":1}"#)
        let client = ServerEndpoint.default.client(token: "tok", transport: transport)
        let page = try await client.listLibraries(query: .init(limit: 1)).ok.body.json
        XCTAssertEqual(page.items.first?.name, "Films")
        XCTAssertEqual(page.items.first?.kind, .movies)
        XCTAssertEqual(page.nextOffset, 1)
        let sent = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(sent.baseURL.absoluteString, "http://localhost:8477/api/v2")
        XCTAssertEqual(sent.request.path, "/libraries?limit=1")
        XCTAssertEqual(sent.request.headerFields[.authorization], "Bearer tok")
    }

    func testSendsOneCapabilityGroupAlone() async throws {
        let transport = RecordingTransport(
            body:
                #"{"action":"continue","stream":{"sessionId":"\#(UID.n(7))","#
                + #""entry":{"position":0,"verdict":"direct_play","#
                + #""videoAction":"copy","audioAction":"copy","subtitleAction":"none","bad":false},"#
                + #""streamUrl":"/s","mediaFileId":"\#(UID.n(1))","streamKind":"file","positionMs":0,"#
                + #""negotiated":{"verdict":"direct_play","width":1920,"height":1080,"bitrate":1},"#
                + #""rungs":[],"sidecars":[]}}"#)
        let client = ServerEndpoint.default.client(token: "tok", transport: transport)
        let route = Components.Schemas.AudioRouteCapabilities(channels: 2, passthroughCodecs: [])
        let update = try await client.updatePlaybackAudioRoute(path: .init(sessionId: 7), body: .json(route)).ok.body
            .json
        XCTAssertEqual(update.action, ._continue)
        let sent = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(sent.request.method, .put)
        XCTAssertEqual(sent.request.path, "/playback/sessions/\(UID.n(7))/audio-route")
        let decoded = try JSONDecoder().decode(
            Components.Schemas.AudioRouteCapabilities.self, from: Data(sent.body.utf8))
        XCTAssertEqual(decoded.channels, 2)
    }

    func testThrowsTheSharedErrorShape() async throws {
        let transport = RecordingTransport(status: .forbidden, body: #"{"code":"pin_locked","message":"locked"}"#)
        let client = ServerEndpoint.default.client(token: "tok", transport: transport)
        do {
            _ = try await client.deleteLibrary(path: .init(libraryId: 1))
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(APIError.from(error), APIError(status: 403, code: .pinLocked, message: "locked"))
        }
    }

    func testAnUnreadableErrorBodyStillCarriesTheStatus() async throws {
        let transport = RecordingTransport(status: .badGateway, body: "<html>")
        let client = ServerEndpoint.default.client(token: nil, transport: transport)
        do {
            _ = try await client.getHealth()
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(APIError.from(error)?.status, 502)
            XCTAssertEqual(APIError.from(error)?.code, ._internal)
        }
    }
}
