import Foundation
import RabbitEarsAPI
import XCTest

@testable import RabbitEarsKit

/// A range in which no program could start is refused before it is
/// queued, in the server's words, since the server's refusal of a queued
/// save arrives only later and drops the station.
@MainActor
final class StationTimesTests: XCTestCase {
    func testARangeThatHoldsNoStartSavesNothingAndSaysWhyAsTheServerWould() async throws {
        let replica = try stationHousehold()
        let model = stationsModel(replica)
        var form = StationForm(kind: .movies)
        form.name = "Late"
        form.schedule = .chosen
        form.times = [StationTimeRange(from: "10:00", to: "11:00"), StationTimeRange(from: "20:05", to: "20:25")]

        let refused = await model.save(form)

        XCTAssertNil(refused)
        XCTAssertEqual(model.fieldErrors, ["times": "20:05 to 20:25 holds no hour start, so nothing would air"])
        let queued = try await replica.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM queue.action") }
        XCTAssertEqual(queued, 0)

        form.times[1].to = "21:01"
        let saved = await model.save(form)

        XCTAssertNotNil(saved)
        XCTAssertEqual(model.fieldErrors, [:])
    }

    func testTheMessageNamesTheTimingAsTheServerSpellsIt() async throws {
        let model = stationsModel(try stationHousehold())
        var form = StationForm(kind: .tv)
        form.name = "Late"
        form.schedule = .chosen
        form.times = [StationTimeRange(from: "20:05", to: "20:25")]
        _ = await model.save(form)
        XCTAssertEqual(model.fieldErrors["times"], "20:05 to 20:25 holds no half_hour start, so nothing would air")
    }

    /// station.TestRangeHoldsABoundary, case for case.
    func testARangeHoldsAStartWhereTheServersRangeHoldsOne() {
        struct Case {
            let timing: Components.Schemas.StationTiming
            let from: String
            let to: String
            let holds: Bool
        }
        let cases = [
            Case(timing: .hour, from: "20:05", to: "20:25", holds: false),
            Case(timing: .hour, from: "20:00", to: "20:25", holds: true),
            Case(timing: .hour, from: "20:05", to: "21:00", holds: false),
            Case(timing: .hour, from: "20:05", to: "21:01", holds: true),
            Case(timing: .halfHour, from: "20:05", to: "20:25", holds: false),
            Case(timing: .halfHour, from: "20:25", to: "20:35", holds: true),
            Case(timing: .hour, from: "23:45", to: "00:10", holds: true),
            Case(timing: .hour, from: "23:45", to: "23:55", holds: false),
            Case(timing: .hour, from: "20:05", to: "20:05", holds: true),
            Case(timing: .continuous, from: "20:05", to: "20:25", holds: true),
        ]
        for test in cases {
            XCTAssertEqual(
                StationForm.holds(StationTimeRange(from: test.from, to: test.to), test.timing), test.holds,
                "\(test.timing) \(test.from)-\(test.to)")
        }
    }
}
