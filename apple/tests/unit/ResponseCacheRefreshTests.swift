import Foundation
import HTTPTypes
import RabbitEarsAPI
import XCTest

@testable import RabbitEarsKit

/// Holds the server's answers until opened; after five seconds it opens by
/// itself, so a read that waits on it fails its test rather than hanging.
final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false

    func open() { lock.withLock { opened = true } }

    func wait() async throws {
        for _ in 0..<1000 where !lock.withLock({ opened }) { try await Task.sleep(for: .milliseconds(5)) }
    }
}

/// A read answered from what is kept while the server is asked behind it,
/// and what a write does to that.
extension ResponseCacheTests {
    func testAKeptAnswerIsReadAtOnceAndTheServersChangeIsKeptAndSignalledOnce() async throws {
        let live = LiveFeed(cache: cache)
        _ = try await movies()
        let gate = Gate()
        transport.hold = { _ in try await gate.wait() }
        listsNext(21)
        let listed = try await atOnce { try await movies() }
        XCTAssertEqual(listed, [20], "the kept answer, while the server has not answered")
        XCTAssertEqual(asked("/items"), 2, "the server is asked behind it")
        XCTAssertEqual(live.watched, 0)

        gate.open()
        try await until { live.watched > 0 }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(live.watched, 1)
    }

    func testAnswersRefreshedTogetherSignalOnce() async throws {
        let live = LiveFeed(cache: cache)
        func states() async throws -> [Int64] {
            try await client.listWatchStates(path: .init(profileId: 1), query: .init()).ok.body.json.items.map(\.itemId)
        }
        _ = try await movies()
        _ = try await states()
        let gate = Gate()
        transport.hold = { _ in try await gate.wait() }
        listsNext(21)
        transport.routes["GET /profiles/1/watch-state"] = (.ok, Fixtures.page([Fixtures.watch(21, position: 5)]))
        _ = try await movies()
        _ = try await states()

        gate.open()
        try await until { live.watched > 0 }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(live.watched, 1)
        let listed = try await movies()
        let states = try await states()
        XCTAssertEqual(listed, [21])
        XCTAssertEqual(states, [21])
    }

    func testTheSameAnswerFromTheServerSignalsNothing() async throws {
        let live = LiveFeed(cache: cache)
        _ = try await movies()
        _ = try await movies()
        try await until { asked("/items") == 2 }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(live.watched, 0)

        _ = try await movies()
        try await until { asked("/items") == 3 }
        XCTAssertEqual(asked("/items"), 3, "each read asks behind it again")
    }

    func testReadingAgainOnTheSignalTakesTheNewAnswerWithoutAskingAgain() async throws {
        let live = LiveFeed(cache: cache)
        let events = live.events()
        let view = Task {
            for await _ in events { reads.append(try await movies()) }
        }
        defer { view.cancel() }
        _ = try await movies()
        listsNext(21)
        _ = try await movies()

        try await until { !reads.isEmpty }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(reads, [[21]])
        XCTAssertEqual(asked("/items"), 2, "the read on the signal is answered from what the refresh kept")
        XCTAssertEqual(live.watched, 1)
    }

    func testWithTheServerGoneAKeptAnswerIsReadAtOnceAndStays() async throws {
        let live = LiveFeed(cache: cache)
        _ = try await movies()
        let gate = Gate()
        transport.hold = { _ in
            try await gate.wait()
            throw URLError(.notConnectedToInternet)
        }
        let listed = try await atOnce { try await movies() }
        XCTAssertEqual(listed, [20])
        XCTAssertEqual(asked("/items"), 2)

        gate.open()
        for _ in 0..<400 where asked("/items") < 3 {
            let kept = try await movies()
            XCTAssertEqual(kept, [20])
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(asked("/items"), 3, "the failed refresh is over, so the next read asks again")
        try await Task.sleep(for: .milliseconds(50))
        let kept = try await movies()
        XCTAssertEqual(kept, [20], "nothing kept is dropped")
        XCTAssertEqual(live.watched, 0)
    }

    func testAnErrorFromTheServerDropsTheKeptAnswerAndSignals() async throws {
        let live = LiveFeed(cache: cache)
        _ = try await movies()
        transport.routes["GET /items"] = (.notFound, Fixtures.error("not_found"))
        let listed = try await movies()
        XCTAssertEqual(listed, [20])

        try await until { live.watched > 0 }
        XCTAssertEqual(live.watched, 1)
        do {
            let gone = try await movies()
            XCTFail("the dropped answer was read again: \(gone)")
        } catch {
            XCTAssertEqual(APIError.from(error)?.status, 404)
        }
        XCTAssertEqual(asked("/items"), 3, "with nothing kept the read waits on the server")
    }

    func testAServerThatFailsLeavesTheKeptAnswerAsOneThatIsGoneDoes() async throws {
        let live = LiveFeed(cache: cache)
        _ = try await movies()
        transport.routes["GET /items"] = (.serviceUnavailable, Fixtures.error("unavailable"))
        var listed = try await movies()
        XCTAssertEqual(listed, [20])
        try await until { asked("/items") == 2 }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(live.watched, 0)

        try await markWatched()
        listed = try await movies()
        XCTAssertEqual(listed, [20], "the kept one, though asked for first")
    }

    func testAfterAWriteTheServerAnsweredTheNextReadAsksFirst() async throws {
        _ = try await movies()
        listsNext(21)
        try await markWatched()
        var listed = try await movies()
        XCTAssertEqual(listed, [21], "the server's answer, waited on")
        listed = try await movies()
        XCTAssertEqual(listed, [21])
        try await until { asked("/items") == 3 }
        XCTAssertEqual(asked("/items"), 3, "then reads take the kept answer and ask behind it")

        try await Task.sleep(for: .milliseconds(50))
        listsNext(22)
        try await markWatched()
        transport.failure = URLError(.notConnectedToInternet)
        listed = try await movies()
        XCTAssertEqual(listed, [21], "the kept one while the server is gone")
    }

    func testAWriteThatNeverReachedTheServerLeavesReadsOnTheKeptAnswer() async throws {
        _ = try await movies()
        transport.failure = URLError(.notConnectedToInternet)
        _ = try? await markWatched()
        transport.failure = nil
        let gate = Gate()
        defer { gate.open() }
        transport.hold = { _ in try await gate.wait() }
        listsNext(21)
        let listed = try await atOnce { try await movies() }
        XCTAssertEqual(listed, [20])
    }

    func testThePlayersPositionReportsMarkNothing() async throws {
        transport.routes["PUT /playback/sessions/7/position"] = (.noContent, "")
        _ = try await movies()
        _ = try await client.reportPlaybackPosition(
            path: .init(sessionId: 7), body: .json(.init(positionMs: 60_000, paused: false))
        ).noContent
        let gate = Gate()
        defer { gate.open() }
        transport.hold = { _ in try await gate.wait() }
        listsNext(21)
        let listed = try await atOnce { try await movies() }
        XCTAssertEqual(listed, [20])
    }

    func testALaunchPaintsTheKeptLibraryBeforeTheServerAnswers() async throws {
        await CatalogModel(client: client, profileId: 1).load()

        let gate = Gate()
        defer { gate.open() }
        let slow = RoutingTransport(transport.routes)
        slow.hold = { sent in
            guard sent.path != "/me" else { return }
            try await gate.wait()
            throw URLError(.timedOut)
        }
        let relaunched = ServerEndpoint.default.client(token: "t", transport: slow, cache: makeCache())
        _ = try await relaunched.getMe()
        let model = CatalogModel(client: relaunched, profileId: 1)
        try await atOnce { await model.load() }
        XCTAssertTrue(model.loaded)
        XCTAssertEqual(model.catalog.item(20)?.parsedTitle, "Dune")
        XCTAssertTrue(model.catalog.isInProgress(20))
        try await until { asked("/items", in: slow) > 0 }
        XCTAssertGreaterThan(asked("/items", in: slow), 0, "then asks the server")

        gate.open()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(model.error, "a refresh that fails behind a painted library says nothing")
        XCTAssertEqual(model.catalog.item(20)?.parsedTitle, "Dune")
    }

    /// Polls for what arrives off the main actor, as a signal or a refresh.
    private func until(_ done: () -> Bool) async throws {
        for _ in 0..<400 where !done() { try await Task.sleep(for: .milliseconds(5)) }
    }
}
