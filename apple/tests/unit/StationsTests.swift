import Foundation
import HTTPTypes
import RabbitEarsAPI
import XCTest

@testable import RabbitEarsKit

extension Fixtures {
    static func program(
        _ id: Int64, _ title: String, kind: String = "movie", starts: String = "2026-11-15T14:00:00Z",
        ends: String = "2026-11-15T15:52:00Z", durationMs: Int64 = 6_720_000
    ) -> String {
        let object =
            switch kind {
            case "song": #""song":\#(Fixtures.song(id, title))"#
            case "episode":
                #""item":\#(Fixtures.item(id, "episode", title, season: 2, episode: 5)),"#
                    + #""show":\#(Fixtures.item(90, "show", "Pocket Dragons"))"#
            default: #""item":\#(Fixtures.item(id, kind, title))"#
            }
        return #"{"itemId":\#(id),"editionId":\#(id * 10),"kind":"\#(kind)","startsAt":"\#(starts)","#
            + #""endsAt":"\#(ends)","durationMs":\#(durationMs),\#(object)}"#
    }

    /// `upNext` defaults to `next` alone, as the server's next is the first of it.
    static func onAir(
        _ status: String, now: String? = nil, position: Int64? = nil, next: String? = nil, upNext: [String]? = nil
    ) -> String {
        let following = upNext ?? next.map { [$0] } ?? []
        var fields = [#""status":"\#(status)""#, #""upNext":[\#(following.joined(separator: ","))]"#]
        if let now { fields.append(#""now":\#(now)"#) }
        if let position { fields.append(#""positionMs":\#(position)"#) }
        if let next { fields.append(#""next":\#(next)"#) }
        return "{\(fields.joined(separator: ","))}"
    }

    static func station(
        _ id: Int64, _ name: String, kind: String = "movies", owner: Int64 = 1, visibility: String = "household",
        days: [String] = [], times: String = "[]", rating: String? = nil, onAir: String = onAir("off_schedule")
    ) -> String {
        let rated = rating.map { #","rating":"\#($0)""# } ?? ""
        let dayList = days.map { #""\#($0)""# }.joined(separator: ",")
        return #"{"id":\#(id),"name":"\#(name)","kind":"\#(kind)","ownerId":\#(owner),"householdId":1,"#
            + #""playlistId":3,"order":"random","visibility":"\#(visibility)","timing":"hour","days":[\#(dayList)],"#
            + #""times":\#(times)\#(rated),"onAir":\#(onAir),"#
            + #""createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z"}"#
    }

    static let lantern = program(20, "The Lantern Keeper")
    static let salt = program(21, "Salt and Ember", starts: "2026-11-15T16:00:00Z", ends: "2026-11-15T18:18:00Z")
    static let bigScreen = station(
        5, "The Big Screen", rating: "PG-13", onAir: onAir("on_air", now: lantern, position: 4_328_000, next: salt))
}

/// A calendar fixed to UTC and US English, so times read the same on any Mac.
private let utc: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    calendar.locale = Locale(identifier: "en_US")
    return calendar
}()

/// ICU puts a narrow no-break space before AM and PM.
private func clock(_ text: String) -> String { text.replacingOccurrences(of: " PM", with: "\u{202F}PM") }

final class StationTextTests: XCTestCase {
    private func onAir(_ json: String) -> StationOnAir { Fixtures.decode(json) }

    func testOnAirSaysWhatIsOnAndWhatIsNext() {
        let lines = StationText.lines(
            onAir(Fixtures.onAir("on_air", now: Fixtures.lantern, next: Fixtures.salt)),
            kind: .movies, calendar: utc)
        XCTAssertEqual(lines, ["On now: The Lantern Keeper", clock("Next: Salt and Ember at 4:00 PM")])
    }

    func testBetweenProgramsSaysWhenWhatIsNextStarts() {
        let gap = onAir(Fixtures.onAir("between_programs", next: Fixtures.salt))
        XCTAssertEqual(
            StationText.lines(gap, kind: .movies, calendar: utc), [clock("Up next at 4:00 PM: Salt and Ember")])
        let song = onAir(Fixtures.onAir("between_programs", next: Fixtures.program(31, "Slow Tide", kind: "song")))
        XCTAssertEqual(
            StationText.waiting(song, kind: .music, calendar: utc), clock("Up next at 2:00 PM: Slow Tide · Radiohead"),
            "a gap on a music station has a time too")
    }

    func testAMusicStationsNextHasNoTime() {
        let next = Fixtures.program(31, "Slow Tide", kind: "song")
        let lines = StationText.lines(
            onAir(Fixtures.onAir("on_air", now: Fixtures.program(30, "Paper Lanterns", kind: "song"), next: next)),
            kind: .music, calendar: utc)
        XCTAssertEqual(lines, ["On now: Paper Lanterns · Radiohead", "Next: Slow Tide · Radiohead"])
    }

    func testAMusicStationsUpNextIsEverySongInPlayOrder() {
        let songs = [31, 32, 33].map { Fixtures.program(Int64($0), "Song \($0)", kind: "song") }
        let onAir: StationOnAir = Fixtures.decode(
            Fixtures.onAir(
                "on_air", now: Fixtures.program(30, "Paper Lanterns", kind: "song"), next: songs[0], upNext: songs))
        XCTAssertEqual(StationText.upNext(onAir).map(\.id), [31, 32, 33])
    }

    func testOffScheduleSaysWhichDayItIsBack() {
        let friday = Fixtures.program(22, "Moon Pie", starts: "2026-11-20T22:00:00Z", ends: "2026-11-20T23:30:00Z")
        let back = onAir(Fixtures.onAir("off_schedule", next: friday))
        let sunday = utc.date(from: DateComponents(year: 2026, month: 11, day: 15, hour: 9))!
        XCTAssertEqual(
            StationText.lines(back, kind: .movies, calendar: utc, now: sunday), [clock("Back Friday at 10:00 PM")])
        let friday9 = utc.date(from: DateComponents(year: 2026, month: 11, day: 20, hour: 9))!
        XCTAssertEqual(
            StationText.lines(back, kind: .movies, calendar: utc, now: friday9), [clock("Back today at 10:00 PM")])
    }

    func testNothingScheduledIsOffTheAir() {
        XCTAssertEqual(
            StationText.lines(onAir(Fixtures.onAir("off_schedule")), kind: .tv, calendar: utc), ["Off the air"])
    }

    func testAnEpisodeIsNamedByItsShowAndCode() {
        let episode: StationProgram = Fixtures.decode(Fixtures.program(23, "Hatchlings", kind: "episode"))
        XCTAssertEqual(StationText.title(episode), "Pocket Dragons · S2 E5")
    }

    func testTheTileShowsWhatIsOnElseWhatIsNextElseNothing() {
        XCTAssertEqual(
            StationText.art(onAir(Fixtures.onAir("on_air", now: Fixtures.lantern, next: Fixtures.salt)))?.itemId, 20)
        XCTAssertEqual(StationText.art(onAir(Fixtures.onAir("between_programs", next: Fixtures.salt)))?.itemId, 21)
        XCTAssertNil(StationText.art(onAir(Fixtures.onAir("off_schedule"))))
    }

    func testProgressRunsOnTheProgramsClock() {
        let program: StationProgram = Fixtures.decode(Fixtures.lantern)
        let now = utc.date(from: DateComponents(year: 2026, month: 11, day: 15, hour: 15, minute: 12))!
        let progress = StationText.progress(program, at: now)
        XCTAssertEqual(progress.elapsed, 72 * 60)
        XCTAssertEqual(progress.remaining, 40 * 60)
        XCTAssertEqual(progress.fraction, 72.0 / 112, accuracy: 0.0001)
        let early = StationText.progress(program, at: program.startsAt.addingTimeInterval(-5))
        XCTAssertEqual(early.elapsed, 0)
        XCTAssertEqual(early.fraction, 0)
    }

    func testHomesOnNowTileNamesTheStationWithItsKind() {
        for (kind, label) in [("movies", "Movies"), ("tv", "TV"), ("music", "Music")] {
            let station: Station = Fixtures.decode(Fixtures.station(1, "Marvel", kind: kind))
            XCTAssertEqual(StationText.onNowName(station), "\(label): Marvel")
        }
    }

    func testHomesOnNowTileSaysItTunesIn() {
        let movies: Station = Fixtures.decode(Fixtures.station(1, "Marvel"))
        XCTAssertEqual(StationText.onNowLabel(movies), "Watch Movies: Marvel")
        let music: Station = Fixtures.decode(Fixtures.station(2, "Kitchen Radio", kind: "music"))
        XCTAssertEqual(StationText.onNowLabel(music), "Listen to Music: Kitchen Radio")
    }

    func testHomesOnNowBarIsTheLivePositionOverTheProgramsLength() {
        let station: Station = Fixtures.decode(Fixtures.bigScreen)
        XCTAssertEqual(
            try XCTUnwrap(StationText.onNowFraction(station.onAir)), 4_328_000.0 / 6_720_000, accuracy: 0.0001)
        let past: StationOnAir = Fixtures.decode(
            Fixtures.onAir("on_air", now: Fixtures.lantern, position: 9_000_000, next: Fixtures.salt))
        XCTAssertEqual(StationText.onNowFraction(past), 1)
        let unplaced: StationOnAir = Fixtures.decode(Fixtures.onAir("on_air", now: Fixtures.lantern))
        XCTAssertNil(StationText.onNowFraction(unplaced))
        let none: StationOnAir = Fixtures.decode(Fixtures.onAir("between_programs", next: Fixtures.salt))
        XCTAssertNil(StationText.onNowFraction(none))
        let empty: StationOnAir = Fixtures.decode(
            Fixtures.onAir(
                "on_air", now: Fixtures.program(1, "Zero", durationMs: 0), position: 0))
        XCTAssertNil(StationText.onNowFraction(empty))
    }

    func testThePageNamesTypeRatingAndVisibility() {
        let station: Station = Fixtures.decode(Fixtures.bigScreen)
        XCTAssertEqual(StationText.kind(station.kind), "Movies station")
        XCTAssertEqual(StationText.rating(station), "PG-13")
        XCTAssertEqual(StationText.visibility(station.visibility), "Household")
        let music: Station = Fixtures.decode(Fixtures.station(6, "Kitchen Radio", kind: "music", visibility: "server"))
        XCTAssertEqual(StationText.rating(music), "None")
        XCTAssertEqual(StationText.visibility(music.visibility), "Server")
        let now = utc.date(from: DateComponents(year: 2026, month: 11, day: 15, hour: 15, minute: 12))!
        XCTAssertEqual(
            StationText.summary(station.onAir, kind: station.kind, calendar: utc, now: now),
            clock("On now: The Lantern Keeper, 40m left. Next: Salt and Ember at 4:00 PM."))
    }
}

final class StationFormTests: XCTestCase {
    func testAStationWithDaysOrTimesHasAChosenSchedule() {
        let station: Station = Fixtures.decode(
            Fixtures.station(
                7, "Creature Double", visibility: "private", days: ["saturday", "friday"],
                times: #"[{"from":"22:00","to":"02:00"}]"#))
        let form = StationForm(station)
        XCTAssertEqual(form.name, "Creature Double")
        XCTAssertEqual(form.kind, .movies)
        XCTAssertEqual(form.order, .random)
        XCTAssertEqual(form.visibility, ._private)
        XCTAssertEqual(form.schedule, .chosen)
        XCTAssertEqual(form.days, [.friday, .saturday])
        XCTAssertEqual(form.times, [StationTimeRange(from: "22:00", to: "02:00")])
        XCTAssertEqual(StationForm(Fixtures.decode(Fixtures.bigScreen) as Station).schedule, .continuous)
    }

    func testTheInputTrimsTheNameAndSendsDaysInWeekOrder() throws {
        var form = StationForm(kind: .tv)
        form.name = "  Creature Double "
        form.visibility = .household
        form.schedule = .chosen
        form.days = [.sunday, .friday, .monday]
        form.times = [StationTimeRange(from: "22:00", to: "02:00")]
        let input = try XCTUnwrap(form.input)
        XCTAssertEqual(input.name, "Creature Double")
        XCTAssertNil(input.playlistId, "a station holds its own playlist")
        XCTAssertEqual(input.kind, .tv)
        XCTAssertEqual(input.order, .playlist)
        XCTAssertEqual(input.visibility, .household)
        XCTAssertEqual(input.days, [.monday, .friday, .sunday])
        XCTAssertEqual(input.times, [StationTimeRange(from: "22:00", to: "02:00")])
    }

    func testContinuousClearsTheScheduleAndServerKeepsTheVisibility() throws {
        var form = StationForm(Fixtures.decode(Fixtures.station(7, "Big", visibility: "server", days: ["friday"])))
        form.schedule = .continuous
        let input = try XCTUnwrap(form.input)
        XCTAssertEqual(input.days, [])
        XCTAssertEqual(input.times, [])
        XCTAssertNil(input.visibility, "only an admin changes a server station's visibility")
        XCTAssertTrue(form.serverWide)
    }

    func testTimingStartsAtTheKindsAndIsSent() throws {
        XCTAssertEqual(StationForm(kind: .movies).timing, .hour)
        XCTAssertEqual(StationForm(kind: .tv).timing, .halfHour)
        XCTAssertEqual(StationForm(kind: .music).timing, .continuous)
        var form = StationForm(Fixtures.decode(Fixtures.bigScreen) as Station)
        XCTAssertEqual(form.timing, .hour)
        form.name = "Big"
        form.timing = .continuous
        XCTAssertEqual(try XCTUnwrap(form.input).timing, .continuous)
        XCTAssertEqual(StationText.timing(.halfHour), "On the hour or half hour")
    }

    func testNoNameHasNoInput() {
        XCTAssertNil(StationForm(kind: .music).input)
        var form = StationForm(kind: .music)
        form.name = " "
        XCTAssertNil(form.input)
    }

    func testATimeReadsAndWritesAsServerClockText() {
        let date = StationForm.date("22:30")
        XCTAssertEqual(StationForm.clock(date), "22:30")
        XCTAssertEqual(StationForm.clock(StationForm.date("02:05")), "02:05")
    }
}

@MainActor
final class StationsModelTests: XCTestCase {
    var transport: RoutingTransport!
    var model: StationsModel!

    override func setUp() async throws {
        transport = RoutingTransport([
            "GET /stations": (
                .ok,
                Fixtures.page([
                    Fixtures.bigScreen,
                    Fixtures.station(
                        7, "Creature Double", onAir: Fixtures.onAir("between_programs", next: Fixtures.salt)),
                ])
            )
        ])
        model = StationsModel(
            client: ServerEndpoint(userInput: "192.168.1.9")!.client(token: "t", transport: transport), profileId: 1)
    }

    func testAListAsksForItsKind() async {
        let stations = await model.list(.movies)
        XCTAssertEqual(stations?.map(\.name), ["The Big Screen", "Creature Double"])
        XCTAssertEqual(transport.queries(.get, "/stations").first?.contains("kind=movies"), true)
    }

    func testOnNowIsEveryKindWithSomethingOn() async {
        let stations = await model.onNow()
        XCTAssertEqual(stations.map(\.id), [5])
        XCTAssertEqual(transport.queries(.get, "/stations").first?.contains("kind"), false)
    }

    func testTheScheduleLeavesTheDayToTheServer() async {
        transport.routes["GET /stations/5/schedule"] = (.ok, Fixtures.page([Fixtures.lantern, Fixtures.salt]))
        let programs = await model.schedule(of: 5)
        XCTAssertEqual(programs?.map(\.itemId), [20, 21])
        XCTAssertEqual(transport.queries(.get, "/stations/5/schedule"), ["limit=200"])
    }

    func testOnlyTheOwnerOwnsIt() {
        XCTAssertTrue(model.isOwner(Fixtures.decode(Fixtures.bigScreen)))
        XCTAssertFalse(model.isOwner(Fixtures.decode(Fixtures.station(8, "Theirs", owner: 2))))
    }

    func testSaveCreatesThenReplaces() async throws {
        transport.routes["POST /stations"] = (.created, Fixtures.station(9, "Late show"))
        transport.routes["PUT /stations/9"] = (.ok, Fixtures.station(9, "Later show"))
        var form = StationForm(kind: .music)
        form.name = "Late show"
        let made = await model.save(form)
        XCTAssertEqual(made?.id, 9)
        XCTAssertNil(transport.json(.post, "/stations")?["playlistId"])
        XCTAssertEqual(transport.json(.post, "/stations")?["kind"] as? String, "music")
        form.name = "Later show"
        let saved = await model.save(form, as: 9)
        XCTAssertEqual(saved?.name, "Later show")
        XCTAssertEqual(transport.json(.put, "/stations/9")?["name"] as? String, "Later show")
        XCTAssertNil(model.error)
    }

    func testARefusedSaveShowsEachFieldsMessage() async {
        transport.routes["POST /stations"] = (
            .badRequest,
            #"{"code":"bad_request","message":"invalid request","#
                + #""fields":[{"field":"name","message":"too long"}]}"#
        )
        var form = StationForm(kind: .movies)
        form.name = "Late show"
        let made = await model.save(form)
        XCTAssertNil(made)
        XCTAssertEqual(model.fieldErrors, ["name": "too long"])
        transport.routes["POST /stations"] = (.created, Fixtures.station(9, "Late show"))
        _ = await model.save(form)
        XCTAssertEqual(model.fieldErrors, [:])
    }

    func testRescheduleAndDelete() async {
        transport.routes["POST /stations/5/reschedule"] = (.ok, Fixtures.bigScreen)
        transport.routes["DELETE /stations/5"] = (.noContent, "")
        let rescheduled = await model.reschedule(5)
        XCTAssertEqual(rescheduled?.id, 5)
        let deleted = await model.delete(5)
        XCTAssertTrue(deleted)
        XCTAssertEqual(transport.paths(.delete), ["/stations/5"])
    }

    func testMineAreTheOwnersStationsKeptThroughSavesAndDeletes() async {
        transport.routes["GET /stations"] = (
            .ok, Fixtures.page([Fixtures.bigScreen, Fixtures.station(8, "Theirs", owner: 2)])
        )
        await model.loadMine()
        XCTAssertEqual(model.mine.map(\.id), [5])
        transport.routes["POST /stations"] = (.created, Fixtures.station(9, "Late tunes", kind: "music"))
        var form = StationForm(kind: .music)
        form.name = "Late tunes"
        _ = await model.save(form)
        XCTAssertEqual(model.mine.map(\.id), [5, 9])
        XCTAssertEqual(model.mine(.music).map(\.id), [9])
        transport.routes["PUT /stations/9"] = (.ok, Fixtures.station(9, "Later tunes", kind: "music"))
        _ = await model.save(form, as: 9)
        XCTAssertEqual(model.mine.map(\.name), ["The Big Screen", "Later tunes"])
        transport.routes["DELETE /stations/5"] = (.noContent, "")
        await model.delete(5)
        XCTAssertEqual(model.mine.map(\.id), [9])
    }
}
