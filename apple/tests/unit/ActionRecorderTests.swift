import Foundation
import GRDB
import HTTPTypes
import OpenAPIRuntime
import RabbitEarsAPI
import Synchronization
import XCTest

@testable import RabbitEarsKit

final class ActionRecorderTests: ActionQueueCase {
    static let rank = "a0"

    /// Calls by operation id, given the action's instant.
    static let calls: [(String, @Sendable (Client, Date) async throws -> Void)] = [
        (
            "putWatchState",
            {
                _ = try await $0.putWatchState(
                    path: .init(profileId: 2, itemId: 40),
                    body: .json(.init(watched: false, positionMs: 61_500, editionId: 7, at: $1)))
            }
        ),
        (
            "recordPlay",
            {
                _ = try await $0.recordPlay(
                    path: .init(profileId: 2, itemId: 40), body: .json(.init(at: $1, editionId: 7)))
            }
        ),
        (
            "addPlaylistEntry",
            {
                _ = try await $0.addPlaylistEntry(
                    path: .init(profileId: 2, playlistId: 3),
                    body: .json(.init(itemId: 40, rank: ActionRecorderTests.rank, editionId: 7)))
                _ = $1
            }
        ),
        (
            "setProfilePreferences",
            {
                _ = try await $0.setProfilePreferences(
                    path: .init(profileId: 2), body: .json(.init(color: "#2E6B5B", autoplay: false)))
                _ = $1
            }
        ),
        (
            "deleteWatchState",
            { _ = try await $0.deleteWatchState(path: .init(profileId: 2, itemId: 40), query: .init(at: $1)) }
        ),
    ]

    func testARecordedCallIsTheRequestTheGeneratedClientSends() async throws {
        let rank = try FractionalIndex.key(between: nil, and: nil)
        XCTAssertEqual(rank, Self.rank)
        let calls = Self.calls
        let replica = try replica()
        let queue = queue(replica)
        let real = ServerEndpoint.default.client(token: "tok-1", transport: transport)

        for (operation, call) in calls {
            try? await call(real, Self.now)
            let sent = try XCTUnwrap(transport.sent.last)
            try await queue.act(as: 2, touching: [try .row("account", 2)], call: call, apply: { _, _ in })

            let row = try await replica.read { db in
                try Row.fetchOne(
                    db, sql: "SELECT operation_id, method, path, body FROM queue.action ORDER BY seq DESC LIMIT 1"
                ).map {
                    [
                        $0["operation_id"], $0["method"], $0["path"],
                        ($0["body"] as Data?).flatMap { String(bytes: $0, encoding: .utf8) },
                    ] as [String?]
                }
            }
            let path = sent.query.isEmpty ? sent.path : "\(sent.path)?\(sent.query)"
            XCTAssertEqual(row, [operation, sent.method.rawValue, path, sent.body.isEmpty ? nil : sent.body])
        }
        XCTAssertEqual(transport.paths(.post).filter { $0 == "/sync/actions" }, [], "recording sends nothing")
        let bodies = transport.sent.map(\.body).joined()
        XCTAssertTrue(bodies.contains("2027-01-15T08:00:00.123Z"), "dates carry milliseconds: \(bodies)")
        XCTAssertTrue(bodies.contains(rank))
    }

    func testIdsInPathsQueriesAndBodiesAreLowercase() async throws {
        let (profile, item, parent) = (UID.new(), UID.new(), UID.new())
        let client = Client.connect(to: ServerEndpoint.default.baseURL, token: nil, transport: ActionRecorder())
        func recorded(_ call: (Client) async throws -> Void) async throws -> ActionRecorder.Recorded {
            do {
                try await call(client)
            } catch let error as ClientError {
                return try XCTUnwrap(error.underlyingError as? ActionRecorder.Recorded)
            }
            throw ActionQueue.Failure.unsendable("no call made")
        }

        let entry = try await recorded {
            _ = try await $0.addPlaylistEntry(
                path: .init(profileId: profile, playlistId: item), body: .json(.init(id: parent, itemId: item)))
        }
        let list = try await recorded {
            _ = try await $0.listWatchStates(path: .init(profileId: profile), query: .init(parentId: parent))
        }

        XCTAssertEqual(entry.path, "/profiles/\(profile)/playlists/\(item)/entries")
        XCTAssertEqual(list.path, "/profiles/\(profile)/watch-state?parentId=\(parent)")
        let body = try XCTUnwrap(
            entry.body.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: String])
        XCTAssertEqual(body, ["id": parent.description, "itemId": item.description])
    }

    /// The batch carries each stored body as decoding it whole into the container would.
    func testAStoredBodyIsSentAsDecodingItWouldSendIt() async throws {
        let bodies = [
            #"{"a":{"b":[1,-2,0,9223372036854775807,-9223372036854775808]},"c":1.5,"d":1.0,"e":-0.25,"f":1e300,"#
                + #""g":true,"h":false,"i":null,"j":"Grüße ☃ 😀 \"q\" \\ \/ \u0001","k":[],"l":{},"m":[[{"n":[null]}]],"#
                + #""o":"2027-01-15T08:00:00.123Z","p":12345678901234567,"q":0.1,"r":-0.0,"s":1e-7}"#,
            #"[1,true,"x",null,2.5,{"a":false}]"#,
            #"{"itemIds":["\#(UID.n(1))","\#(UID.n(2))"],"watched":true,"at":"2027-01-15T08:00:00.123Z"}"#,
        ]
        let client = Client.connect(to: ServerEndpoint.default.baseURL, token: nil, transport: ActionRecorder())
        func sent(_ body: OpenAPIValueContainer) async throws -> Data? {
            let action = Components.Schemas.SyncAction(
                id: "a", seq: 1, operationId: "op", method: .post, path: "/p", body: body, actingProfileId: 1,
                at: Self.now, touched: [])
            do {
                _ = try await client.replaySyncActions(body: .json(.init(apiVersion: "1", actions: [action])))
            } catch let error as ClientError {
                return try XCTUnwrap(error.underlyingError as? ActionRecorder.Recorded).body
            }
            return nil
        }
        for body in bodies {
            let data = Data(body.utf8)
            let decoded = try await sent(JSONDecoder().decode(OpenAPIValueContainer.self, from: data))
            let parsed = try await sent(ActionQueue.body(data))
            XCTAssertNotNil(parsed)
            XCTAssertEqual(parsed, decoded, body)
        }
    }

    static let spec = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../../openapi.yaml")

    func testTheApiVersionIsTheSpecs() throws {
        let text = try String(contentsOf: Self.spec, encoding: .utf8)
        let version = try XCTUnwrap(text.firstMatch(of: /\ninfo:\n(?:  .*\n)*?  version: (\S+)\n/)?.1)
        XCTAssertEqual(ActionQueue.apiVersion, String(version))
    }

    func testTheTouchedLimitIsTheSpecs() throws {
        let text = try String(contentsOf: Self.spec, encoding: .utf8)
        let schema = try XCTUnwrap(text.range(of: "\n    SyncAction:\n"))
        let touched = try XCTUnwrap(text.range(of: "\n        touched:\n", range: schema.upperBound..<text.endIndex))
        let limit = try XCTUnwrap(text[touched.upperBound...].firstMatch(of: /\n          maxItems: (\d+)\n/)?.1)
        XCTAssertEqual(ActionQueue.touchedLimit, Int(limit))
    }

    func testTheEntriesLimitIsTheSpecs() throws {
        let text = try String(contentsOf: Self.spec, encoding: .utf8)
        let schema = try XCTUnwrap(text.range(of: "\n    PlaylistEntriesInput:\n"))
        let entries = try XCTUnwrap(text.range(of: "\n        entries:\n", range: schema.upperBound..<text.endIndex))
        let limit = try XCTUnwrap(text[entries.upperBound...].firstMatch(of: /\n          maxItems: (\d+)\n/)?.1)
        XCTAssertEqual(ActionQueue.entriesLimit, Int(limit))
    }
}
