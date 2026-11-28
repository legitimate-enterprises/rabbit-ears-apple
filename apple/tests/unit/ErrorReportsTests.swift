import Foundation
import GRDB
import OpenAPIRuntime
import RabbitEarsAPI
import Synchronization
import XCTest

@testable import RabbitEarsKit

/// What the kit tells the server's Logs about errors met on this device,
/// queued as reportClientErrors actions.
final class ErrorReportsTests: ActionQueueCase {
    private struct Broken: Error, CustomStringConvertible {
        var text = "no such column: item.sort_title"
        var description: String { text }
    }

    private final class Clock: Sendable {
        private let value = Mutex(ActionQueueCase.now)
        var now: Date { value.withLock { $0 } }
        func advance(_ seconds: TimeInterval) { value.withLock { $0 += seconds } }
    }

    private let clock = Clock()
    private var reporter: ErrorReporter!

    override func tearDown() {
        reporter?.close()
        super.tearDown()
    }

    /// An open reporter on the queue, acting as UID.n(1), on `clock`.
    private func reporting(_ queue: ActionQueue, _ replica: Replica) -> ErrorReporter {
        let clock = clock
        reporter = ErrorReporter(queue: queue, replica: replica, acting: { 1 }, now: { clock.now })
        reporter.open()
        return reporter
    }

    private struct Report: Sendable {
        let method: String
        let path: String
        let body: Data
        let touched: Int
    }

    private func reports(_ replica: Replica) async throws -> [Report] {
        try await replica.read {
            try Row.fetchAll(
                $0,
                sql: """
                    SELECT a.method, a.path, a.body, (SELECT count(*) FROM queue.action_touch t WHERE t.action = a.seq)
                        AS touched FROM queue.action a WHERE a.operation_id = 'reportClientErrors' ORDER BY a.seq
                    """
            ).map { Report(method: $0["method"], path: $0["path"], body: $0["body"], touched: $0["touched"]) }
        }
    }

    private func entries(_ replica: Replica) async throws -> [[String: Any]] {
        try await reports(replica).flatMap { row -> [[String: Any]] in
            let body = try JSONSerialization.jsonObject(with: row.body) as? [String: Any]
            return body?["entries"] as? [[String: Any]] ?? []
        }
    }

    private func settle() async { try? await Task.sleep(for: .milliseconds(100)) }

    // MARK: Bounds and scrubbing

    func testBoundsCountUnicodeCodePointsAsTheServerDoes() {
        XCTAssertEqual(ErrorReports.bounded("abc", 5), "abc")
        XCTAssertEqual(
            ErrorReports.bounded("e\u{301}xyz", 2), "e\u{301}", "a combining mark is a code point of its own")
        let family = "👨‍👩‍👧"
        XCTAssertEqual(ErrorReports.bounded(family, 3).unicodeScalars.count, 3)
        XCTAssertEqual(ErrorReports.bounded(String(repeating: "é", count: 1200), 1000).unicodeScalars.count, 1000)
    }

    func testAnEntryIsBoundedToTheSpecsLengths() {
        let entry = ErrorReports.entry(
            at: Self.now, message: String(repeating: "m", count: 1500), context: String(repeating: "c", count: 150),
            detail: String(repeating: "d", count: 5000))
        XCTAssertEqual(entry.message.unicodeScalars.count, 1000)
        XCTAssertEqual(entry.context.unicodeScalars.count, 100)
        XCTAssertEqual(entry.detail?.unicodeScalars.count, 4000)
        XCTAssertEqual(entry.at, Self.now)

        let blank = ErrorReports.entry(at: Self.now, message: " ", context: "", detail: "")
        XCTAssertEqual(blank.message, "Unknown error.", "the spec takes no empty message")
        XCTAssertEqual(blank.context, "app")
        XCTAssertNil(blank.detail)
        XCTAssertNotEqual(blank.id, entry.id)
    }

    func testTheScrubberKeepsNoCredentialsAddressesOrStreamKeys() {
        let cases: [(String, String)] = [
            (
                "GET https://ann:hunter2@media.example.com:8477/api/v2/items?token=abc&x=1#top failed",
                "GET https://media.example.com:8477/api/v2/items failed"
            ),
            ("http://rabbit.local/api/v2/me?cursor=5", "http://rabbit.local/api/v2/me"),
            (
                "fetching /api/v2/streams/k3y-S3cret/e1/master.m3u8",
                "fetching /api/v2/streams/[redacted]/e1/master.m3u8"
            ),
            ("live /api/v2/channels/ch4nKey/live.m3u8", "live /api/v2/channels/[redacted]/live.m3u8"),
            ("Authorization: Bearer abc.def-123", "Authorization: Bearer [redacted]"),
            ("sent pin=1234 and password=pw secret", "sent pin=[redacted] and password=[redacted] secret"),
            ("no account for ann.smith+tv@example.co.uk", "no account for [email]"),
            (
                "item 0190a8f2-3c4d-7e5f-8a9b-0c1d2e3f4a5b not found at 12:00",
                "item 0190a8f2-3c4d-7e5f-8a9b-0c1d2e3f4a5b not found at 12:00"
            ),
        ]
        for (text, scrubbed) in cases { XCTAssertEqual(ErrorReports.scrubbed(text), scrubbed, text) }
    }

    func testEntriesAreScrubbedBeforeTheyAreBounded() {
        let entry = ErrorReports.entry(
            at: Self.now, message: "bad answer from https://x.example/a?token=t", context: "ann@example.com",
            detail: "Bearer zzz")
        XCTAssertEqual(entry.message, "bad answer from https://x.example/a")
        XCTAssertEqual(entry.context, "[email]")
        XCTAssertEqual(entry.detail, "Bearer [redacted]")
    }

    func testTheVersionsAreTheAppsAndThePlatformsOwn() {
        XCTAssertFalse(ErrorReports.appVersion.isEmpty)
        XCTAssertLessThanOrEqual(ErrorReports.appVersion.unicodeScalars.count, 64)
        #if os(macOS)
            let platform = "macOS"
        #elseif os(tvOS)
            let platform = "tvOS"
        #else
            let platform = "iOS"
        #endif
        XCTAssertNotNil(ErrorReports.osVersion.wholeMatch(of: #/(macOS|iOS|tvOS) \d+\.\d+(\.\d+)?/#))
        XCTAssertTrue(ErrorReports.osVersion.hasPrefix(platform + " "), ErrorReports.osVersion)
    }

    // MARK: Reporting

    func testAnInternalErrorQueuesOneReportTouchingNothing() async throws {
        let replica = try replica()
        _ = reporting(queue(replica), replica)

        XCTAssertEqual(AppError.from(Broken()), AppError.unexpected, "the person still reads the plain words")

        try await until { try await !reports(replica).isEmpty }
        let rows = try await reports(replica)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.method, "POST")
        XCTAssertEqual(rows.first?.path, "/client-errors")
        XCTAssertEqual(rows.first?.touched, 0)
        let body = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: XCTUnwrap(rows.first?.body)) as? [String: Any])
        XCTAssertEqual(body["appVersion"] as? String, ErrorReports.appVersion)
        XCTAssertEqual(body["osVersion"] as? String, ErrorReports.osVersion)
        let entry = try XCTUnwrap((body["entries"] as? [[String: Any]])?.first)
        XCTAssertEqual(entry["message"] as? String, "no such column: item.sort_title")
        XCTAssertEqual(entry["context"] as? String, "ErrorReportsTests", "the calling file stands for the screen")
        XCTAssertEqual(entry["at"] as? String, "2027-01-15T08:00:00.123Z")
        XCTAssertNotNil(UID(entry["id"] as? String ?? ""), "a UUIDv7")
        XCTAssertTrue((entry["detail"] as? String)?.contains("ErrorReportsTests.swift:") == true)
    }

    func testTheSameErrorTwiceIsQueuedOnce() async throws {
        let replica = try replica()
        _ = reporting(queue(replica), replica)

        _ = AppError.from(Broken())
        _ = AppError.from(Broken())
        _ = AppError.from(Broken(text: "disk I/O error"))

        try await until { try await entries(replica).count == 2 }
        await settle()
        let messages = try await entries(replica).compactMap { $0["message"] as? String }
        XCTAssertEqual(messages.sorted(), ["disk I/O error", "no such column: item.sort_title"])
    }

    func testAtMostTheHourlyLimitIsQueuedInAnyHour() async throws {
        let replica = try replica()
        let reporter = reporting(queue(replica), replica)

        for index in 0..<(ErrorReporter.hourlyLimit + 10) { reporter.report("error \(index)", context: "home") }
        clock.advance(3599)
        reporter.report("one more", context: "home")
        try await until { try await entries(replica).count == ErrorReporter.hourlyLimit }
        await settle()
        let early = try await entries(replica).count
        XCTAssertEqual(early, ErrorReporter.hourlyLimit)
        XCTAssertLessThan(ErrorReporter.hourlyLimit, 100, "well under the server's 100 an hour a device")

        clock.advance(2)
        reporter.report("an hour on", context: "home")
        try await until { try await entries(replica).count == ErrorReporter.hourlyLimit + 1 }
        let later = try await entries(replica).count
        XCTAssertEqual(later, ErrorReporter.hourlyLimit + 1)
    }

    func testWhatIsNotTheAppsFaultIsNotReported() async throws {
        let replica = try replica()
        _ = reporting(queue(replica), replica)
        struct Human: LocalizedError { var errorDescription: String? { "That title is no longer available." } }

        let errors: [any Error] = [
            URLError(.notConnectedToInternet), URLError(.timedOut), URLError(.cancelled), CancellationError(),
            APIError(status: 500, code: ._internal, message: "The server answered 500."),
            APIError(status: 401, code: .unauthorized, message: "Email or password is wrong."),
            AppError.wrongCredentials, Human(),
        ]
        for error in errors { _ = AppError.from(error) }

        await settle()
        let rows = try await reports(replica)
        XCTAssertEqual(rows.count, 0)
    }

    func testAnAnswerThatDoesNotDecodeIsReportedUnderItsOperation() async throws {
        let replica = try replica()
        _ = reporting(queue(replica), replica)
        transport.routes["GET /me"] = (.ok, #"{"account":{}}"#)
        let client = ServerEndpoint.default.client(token: "tok-1", transport: transport)

        do {
            _ = try await client.getMe().ok
            XCTFail("decoded")
        } catch {
            _ = AppError.from(error)
        }

        try await until { try await !entries(replica).isEmpty }
        let entry = try await entries(replica).first
        XCTAssertEqual(entry?["context"] as? String, "getMe")
        XCTAssertTrue((entry?["detail"] as? String)?.hasPrefix("HTTP 200") == true, "\(entry ?? [:])")
    }

    func testNothingIsHeldBeforeAReporterOpens() async throws {
        let replica = try replica()
        let queue = queue(replica)
        _ = AppError.from(Broken())

        let reporter = reporting(queue, replica)
        await reporter.send()

        await settle()
        let rows = try await reports(replica)
        XCTAssertEqual(rows.count, 0, "an error before sign-in is not kept for after it")
    }

    func testWithNoReplicaYetAReportWaitsInMemoryForOne() async throws {
        let replica = try fixture.open()
        XCTAssertTrue(replica.isEmpty)
        let reporter = reporting(queue(replica), replica)

        reporter.report("The replica failed to open.", context: "launch.replica")
        await settle()
        try replica.adopt(fixture.snapshot(version: 5))
        await reporter.send()

        let messages = try await entries(replica).compactMap { $0["message"] as? String }
        XCTAssertEqual(messages, ["The replica failed to open."])
    }

    // MARK: Sending

    func testOfflineAReportStaysQueuedAcrossAReopenedQueueAndGoesOnceBack() async throws {
        let replica = try replica()
        let queue = queue(replica)
        transport.failure = URLError(.notConnectedToInternet)
        try await queue.reportClientErrors([ErrorReports.entry(at: Self.now, message: "boom", context: "home")], as: 1)

        let offline = await queue.flush()
        XCTAssertEqual(offline, .done, "an error report is no unsent change")
        let kept = try await queued(replica)
        XCTAssertEqual(kept.count, 1)

        replica.close()
        let reopened = try fixture.open()
        let value = try await queued(reopened)
        XCTAssertEqual(value, kept, "it outlives the launch")
        transport.failure = nil
        let online = await self.queue(reopened).flush()

        XCTAssertEqual(online, .done)
        XCTAssertEqual(batches().flatMap { $0.actions.map(\.operationId) }, ["reportClientErrors"])
        XCTAssertEqual(batches().first?.actions.first?.touched.count, 0)
        let left = try await queued(reopened)
        XCTAssertEqual(left, [])
    }

    func testARejectedReportIsDroppedWithNoNotice() async throws {
        let replica = try replica()
        let queue = queue(replica)
        transport.respond = { sent in
            sent.path == "/sync/actions"
                ? Self.answer(
                    sent, rejecting: ["reportClientErrors": "too_many_requests", "putWatchState": "forbidden"])
                : nil
        }
        try await queue.reportClientErrors([ErrorReports.entry(at: Self.now, message: "a", context: "home")], as: 1)
        try await watch(queue, item: 40)

        _ = await queue.flush()

        let value = try await queued(replica)
        XCTAssertEqual(value, [])
        XCTAssertEqual(notices.all, ["putWatchState forbidden"], "only the person's own change is told")
    }

    func testAReportRefusedAloneAsABadBatchIsDroppedWithNoNotice() async throws {
        let replica = try replica()
        let queue = queue(replica)
        transport.respond = { sent in
            sent.path == "/sync/actions" ? (.badRequest, Fixtures.error("bad_request")) : nil
        }
        try await queue.reportClientErrors([ErrorReports.entry(at: Self.now, message: "a", context: "home")], as: 1)

        _ = await queue.flush()

        let value = try await queued(replica)
        XCTAssertEqual(value, [])
        XCTAssertEqual(notices.all, [])
    }

    func testAReportTheServerFailsOnHoldsNoChangeBackBehindIt() async throws {
        let replica = try replica()
        let queue = queue(replica)
        let calls = Log<Void>()
        transport.respond = { sent in
            guard sent.path == "/sync/actions" else { return nil }
            // The first batch stops at the report, as a 5xx there stops the server.
            calls.add(())
            return Self.answer(sent, answered: calls.all.count == 1 ? 0 : .max)
        }
        try await queue.reportClientErrors([ErrorReports.entry(at: Self.now, message: "a", context: "home")], as: 1)
        try await watch(queue, item: 40)

        let flushed = await queue.flush()

        XCTAssertEqual(flushed, .done)
        XCTAssertEqual(
            batches().map { $0.actions.map(\.operationId) },
            [["reportClientErrors", "putWatchState"], ["putWatchState"]])
        let value = try await queued(replica)
        XCTAssertEqual(value, [])
        XCTAssertEqual(notices.all, [])
    }

    func testAChangeUnsentBesideAReportIsStillUnsent() async throws {
        let replica = try replica()
        let queue = queue(replica)
        transport.failure = URLError(.notConnectedToInternet)
        try await queue.reportClientErrors([ErrorReports.entry(at: Self.now, message: "a", context: "home")], as: 1)
        try await watch(queue, item: 40)

        let flushed = await queue.flush()

        XCTAssertEqual(flushed, .offline)
        let value = try await queued(replica).count
        XCTAssertEqual(value, 2)
    }
}
