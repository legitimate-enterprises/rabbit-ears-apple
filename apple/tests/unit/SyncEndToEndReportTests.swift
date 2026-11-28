import Foundation
import GRDB
import RabbitEarsAPI
import XCTest

@testable import RabbitEarsKit

/// SyncEndToEndTests of the errors this device reports to the server's Logs.
extension SyncEndToEndTests {
    func testAnErrorReportedHereReachesTheLogsScrubbedAndOnce() async throws {
        let device = try device()
        try await device.engine.catchUp()
        let adult = server.adult.id
        let reporter = ErrorReporter(queue: device.queue, replica: device.replica, acting: { adult })
        let marker = "e2e report \(UUID().uuidString)"

        reporter.report("\(marker) from https://ann:pw@media.example/api/v2/me?token=t", context: "home")
        reporter.report("\(marker) from https://ann:pw@media.example/api/v2/me?token=t", context: "home")
        for _ in 0..<200 {
            let queued = try await device.replica.read {
                try Int.fetchOne($0, sql: "SELECT count(*) FROM queue.action WHERE operation_id = 'reportClientErrors'")
            }
            if queued == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let flushed = await device.queue.flush()
        XCTAssertEqual(flushed, .done)
        XCTAssertEqual(device.notices.all, [])

        let page = try await server.adult.rest.listLogs(query: .init(source: "client", q: marker)).ok.body.json
        XCTAssertEqual(page.items.count, 1, "the same context and message once")
        let entry = try XCTUnwrap(page.items.first)
        XCTAssertEqual(entry.level, .error)
        XCTAssertEqual(entry.message, "\(marker) from https://media.example/api/v2/me")
        XCTAssertEqual(entry.client?.context, "home")
        XCTAssertEqual(entry.client?.platform, .macos)
        XCTAssertEqual(entry.client?.appVersion, ErrorReports.appVersion)
        XCTAssertEqual(entry.client?.osVersion, ErrorReports.osVersion)
        XCTAssertEqual(entry.client?.profileId, adult)
    }
}
