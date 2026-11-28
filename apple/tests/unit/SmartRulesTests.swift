import Foundation
import HTTPTypes
import RabbitEarsAPI
import XCTest

@testable import RabbitEarsKit

@MainActor
final class SmartRulesTests: XCTestCase {
    private var synced: SyncedReplica!
    private var transport: RoutingTransport { synced.transport }

    override func setUp() async throws {
        synced = try SyncedReplica { db in
            try db.account(1, "Avery")
            try db.playlist(4, "Movie night")
            try db.collection(7, "Rainy days")
        }
        addTeardownBlock { [synced] in await synced?.remove() }
        transport.respond = { sent in sent.path == "/sync/actions" ? ActionQueueCase.answer(sent) : nil }
    }

    private func editor(_ target: SmartTarget) -> SmartRulesEditor {
        SmartRulesEditor(target: target, client: synced.client, queue: synced.queue, profileId: 1)
    }

    private static let rulesPath = "/profiles/\(UID.n(1))/playlists/\(UID.n(4))/rules"

    func testEachKindOffersItsOwnFieldsAndCollectionsNoPersonalOnes() {
        XCTAssertEqual(
            SmartField.fields(.playlist(.movies)),
            [
                .title, .year, .runtime, .contentRating, .genre, .cast, .director, .hdr, .uhd, .watched, .playCount,
                .favorite,
            ])
        XCTAssertEqual(
            SmartField.fields(.playlist(.tv)),
            [
                .title, .show, .season, .episode, .year, .runtime, .contentRating, .genre, .cast, .hdr, .uhd, .watched,
                .playCount, .favorite,
            ])
        XCTAssertEqual(
            SmartField.fields(.playlist(.music)),
            [.title, .artist, .album, .year, .genre, .duration, .explicit, .lossless, .playCount, .favorite])
        XCTAssertEqual(
            SmartField.fields(.collection),
            [.title, .year, .runtime, .contentRating, .genre, .cast, .director, .hdr, .uhd])
        XCTAssertFalse(SmartField.fields(.collection).contains(where: \.isPersonal))
        XCTAssertEqual(SmartField.allCases.filter(\.isPersonal), [.watched, .playCount, .favorite])
    }

    func testOperatorsAndTheirLabelsFollowTheFieldsType() {
        XCTAssertEqual(
            SmartOperator.choices(.text).map { $0.label(for: .title) },
            ["is", "is not", "contains", "does not contain", "starts with", "ends with"])
        XCTAssertEqual(
            SmartOperator.choices(.number).map { $0.label(for: .year) },
            ["=", "≠", "less than", "at most", "more than", "at least"])
        XCTAssertEqual(SmartOperator.choices(.boolean).map { $0.label(for: .hdr) }, ["Yes", "No"])
        XCTAssertEqual(SmartField.runtime.unit, "min")
        XCTAssertEqual(SmartField.duration.unit, "s")
        XCTAssertNil(SmartField.year.unit)
        XCTAssertEqual(SmartField.uhd.label, "4K")
        XCTAssertTrue(SmartField.contentRating.suggestions(.playlist(.movies)).contains("PG-13"))
        XCTAssertTrue(SmartField.contentRating.suggestions(.playlist(.tv)).contains("TV-MA"))
        XCTAssertEqual(SmartField.title.suggestions(.playlist(.movies)), [])
    }

    func testChangingAFieldResetsTheOperatorAndClearsAValueOfAnotherType() {
        var row = SmartConditionDraft(field: .title)
        XCTAssertEqual(row.op, ._is)
        row.op = .contains
        row.value = "Heat"
        row.field = .genre
        XCTAssertEqual(row.op, ._is, "the type's first operator")
        XCTAssertEqual(row.value, "Heat", "text stays text")
        row.field = .year
        XCTAssertEqual(row.op, ._is)
        XCTAssertEqual(row.value, "", "a title is no year")
        row.value = "1995"
        row.op = .ge
        row.field = .hdr
        XCTAssertEqual(row.op, .isTrue)
        XCTAssertEqual(row.value, "")
    }

    func testTheLastMinusOfAGroupRemovesItAndTheLimitsHold() {
        let rules = editor(.newPlaylist(name: "Late ones", kind: .movies))
        XCTAssertEqual(rules.groups.count, 1)
        XCTAssertFalse(rules.canRemove, "the only row stays")
        rules.addGroup()
        XCTAssertEqual(rules.groups.count, 2)
        let second = rules.groups[1]
        rules.remove(second.conditions[0].id)
        XCTAssertEqual(rules.groups.count, 1, "its last row took the group")
        rules.addCondition(to: rules.groups[0].id)
        rules.remove(rules.groups[0].conditions[0].id)
        XCTAssertEqual(rules.groups.map(\.conditions.count), [1])

        for _ in 1..<SmartRulesEditor.groupLimit { rules.addGroup() }
        XCTAssertEqual(rules.groups.count, 20)
        XCTAssertFalse(rules.canAddGroup)
        rules.addGroup()
        XCTAssertEqual(rules.groups.count, 20)
        for _ in 0..<40 { rules.addCondition(to: rules.groups[0].id) }
        XCTAssertEqual(rules.groups.map(\.conditions.count).reduce(0, +), 50)
        XCTAssertFalse(rules.canAddCondition)
    }

    func testThePersonalNoteShowsOnlyWhenAPersonalFieldIsUsed() {
        let rules = editor(.newPlaylist(name: "Late ones", kind: .movies))
        XCTAssertFalse(rules.usesPersonal)
        rules.groups[0].conditions[0].field = .watched
        XCTAssertTrue(rules.usesPersonal)
        XCTAssertEqual(SmartRulesEditor.personalNote, "Watched, plays and favorites are yours, the owner's.")
    }

    func testRefusesABlankNameABlankTextAndANumberThatIsNotWhole() async {
        let rules = editor(.playlist(Fixtures.decode(Fixtures.playlist(4, "Movie night", kind: "movies"))))
        rules.name = "  "
        rules.addCondition(to: rules.groups[0].id)
        rules.addCondition(to: rules.groups[0].id)
        rules.groups[0].conditions[0].value = "  "
        rules.groups[0].conditions[1].field = .year
        rules.groups[0].conditions[1].value = "19.5"
        rules.groups[0].conditions[2].field = .hdr
        let saved = await rules.save()
        XCTAssertFalse(saved)
        XCTAssertEqual(rules.nameError, "Enter a name.")
        let ids = rules.groups[0].conditions.map(\.id)
        XCTAssertEqual(rules.errors[ids[0]], "Enter a value.")
        XCTAssertEqual(rules.errors[ids[1]], "Enter a whole number.")
        XCTAssertNil(rules.errors[ids[2]], "a boolean takes no value")
        XCTAssertTrue(transport.sent.isEmpty)
    }

    func testTheBodyCarriesTrimmedTextWholeNumbersAndNoValueForABoolean() {
        let rules = editor(.newPlaylist(name: "Late ones", kind: .movies))
        rules.groups[0].match = .any
        rules.groups[0].conditions[0].op = .contains
        rules.groups[0].conditions[0].value = " Heat "
        rules.addGroup()
        rules.groups[1].conditions[0].field = .year
        rules.groups[1].conditions[0].op = .ge
        rules.groups[1].conditions[0].value = "1990"
        rules.addCondition(to: rules.groups[1].id)
        rules.groups[1].conditions[1].field = .uhd
        rules.groups[1].conditions[1].op = .isFalse
        rules.match = .any
        XCTAssertEqual(
            rules.body,
            SmartRules(
                match: .any,
                groups: [
                    .init(match: .any, conditions: [.init(field: .title, _operator: .contains, text: "Heat")]),
                    .init(
                        match: .all,
                        conditions: [
                            .init(field: .year, _operator: .ge, number: 1990), .init(field: .uhd, _operator: .isFalse),
                        ]),
                ]))
    }

    func testOneGroupReadsAsMatchOfItsConditions() {
        let rules = editor(.newPlaylist(name: "Late ones", kind: .movies))
        rules.topMatch = .any
        XCTAssertEqual(rules.groups[0].match, .any, "with one group the top line is the group's")
        rules.addGroup()
        rules.topMatch = .all
        XCTAssertEqual(rules.match, .all)
        XCTAssertEqual(rules.groups[0].match, .any)
    }

    func testEditingReadsTheRulesAndSavesThemWithARename() async throws {
        let stored =
            #"{"match":"any","groups":[{"match":"all","conditions":["#
            + #"{"field":"genre","operator":"is","text":"Drama"},{"field":"year","operator":"lt","number":2000}]}]}"#
        transport.routes["GET \(Self.rulesPath)"] = (.ok, stored)
        transport.routes["PUT \(Self.rulesPath)"] = (.ok, stored)
        var playlist = Fixtures.decode(Fixtures.playlist(4, "Movie night", kind: "movies"), as: Playlist.self)
        playlist.smart = true
        let rules = editor(.playlist(playlist))
        XCTAssertFalse(rules.ready, "nothing to edit until the rules are read")
        await rules.load()
        XCTAssertTrue(rules.ready)
        XCTAssertEqual(rules.name, "Movie night")
        XCTAssertTrue(rules.namesList)
        XCTAssertEqual(rules.groups[0].conditions.map(\.field), [.genre, .year])
        XCTAssertEqual(rules.groups[0].conditions.map(\.value), ["Drama", "2000"])
        rules.name = "Old dramas"
        let saved = await rules.save()
        XCTAssertTrue(saved, "\(rules.error ?? "")")
        let body = try XCTUnwrap(transport.json(.put, Self.rulesPath))
        XCTAssertEqual(body["match"] as? String, "any")
        XCTAssertEqual(try synced.queued(), ["replacePlaylist PUT /profiles/\(UID.n(1))/playlists/\(UID.n(4))"])
    }

    func testRulesThatCannotBeReadLeaveTheEditorDisabled() async {
        transport.failure = URLError(.notConnectedToInternet)
        var playlist = Fixtures.decode(Fixtures.playlist(4, "Movie night", kind: "movies"), as: Playlist.self)
        playlist.smart = true
        let rules = editor(.playlist(playlist))
        await rules.load()
        XCTAssertFalse(rules.ready)
        XCTAssertEqual(rules.error, "Can't reach that server.")
    }

    func testANewSmartPlaylistIsMadeThenGivenItsRules() async throws {
        transport.respond = { sent in
            switch (sent.method, sent.path) {
            case (.post, "/sync/actions"): ActionQueueCase.answer(sent)
            case (.put, let path) where path.hasSuffix("/rules"): (.ok, sent.body)
            default: nil
            }
        }
        let rules = editor(.newPlaylist(name: " Heat nights ", kind: .tv))
        XCTAssertFalse(rules.namesList, "the name sheet asked it")
        XCTAssertEqual(rules.fields, SmartField.fields(.playlist(.tv)))
        rules.groups[0].conditions[0].value = "Heat"
        let saved = await rules.save()
        XCTAssertTrue(saved, "\(rules.error ?? "")")
        let made = try XCTUnwrap(rules.created)
        let actions = transport.sent.map { "\($0.method) \($0.path)" }
        XCTAssertEqual(actions, ["POST /sync/actions", "PUT /profiles/\(UID.n(1))/playlists/\(made)/rules"])
        let lists: [String] = try await synced.read("SELECT name || ' ' || kind FROM playlist ORDER BY name")
        XCTAssertEqual(lists, ["Heat nights tv", "Movie night movies"])
        XCTAssertEqual(SmartRulesEditor.smartNote, "Fills itself from rules you set.")
    }

    func testARefusedPutPlacesEachMessageOnItsRowAndDeletesTheNewList() async throws {
        let refusal =
            #"{"code":"bad_request","message":"invalid request","fields":["#
            + #"{"field":"groups.1.conditions.0.number","message":"must be a whole number"},"#
            + #"{"field":"groups.0.conditions.0.field","message":"not a collection field"},"#
            + #"{"field":"match","message":"must be all or any"}]}"#
        transport.respond = { sent in
            switch (sent.method, sent.path) {
            case (.post, "/sync/actions"): ActionQueueCase.answer(sent)
            case (.put, let path) where path.hasSuffix("/rules"): (.badRequest, refusal)
            default: nil
            }
        }
        let rules = editor(.newCollection(name: "Short ones"))
        XCTAssertFalse(rules.namesList)
        XCTAssertEqual(rules.fields, SmartField.fields(.collection))
        rules.groups[0].conditions[0].value = "Heat"
        rules.addGroup()
        rules.groups[1].conditions[0].field = .runtime
        rules.groups[1].conditions[0].value = "90"
        let saved = await rules.save()
        XCTAssertFalse(saved)
        XCTAssertNil(rules.created)
        XCTAssertEqual(rules.errors[rules.groups[1].conditions[0].id], "must be a whole number")
        XCTAssertEqual(rules.errors[rules.groups[0].conditions[0].id], "not a collection field")
        XCTAssertEqual(rules.error, "must be all or any")
        let ops = try Fixtures.decode(
            XCTUnwrap(transport.sent.last { $0.path == "/sync/actions" }).body,
            as: Components.Schemas.SyncActionBatch.self
        ).actions.map(\.operationId)
        XCTAssertEqual(ops, ["deleteCollection"], "the collection just made goes again")
        let left: [String] = try await synced.read("SELECT name FROM collection ORDER BY name")
        XCTAssertEqual(left, ["Rainy days"])
    }

    func testOfflineANewListIsNotLeftBehind() async throws {
        transport.respond = nil
        transport.failure = URLError(.notConnectedToInternet)
        let rules = editor(.newPlaylist(name: "Loud", kind: .music))
        rules.groups[0].conditions[0].value = "Loud"
        let saved = await rules.save()
        XCTAssertFalse(saved)
        XCTAssertEqual(rules.error, "Can't reach that server.")
        let names: [String] = try await synced.read("SELECT name FROM playlist ORDER BY name")
        XCTAssertEqual(names, ["Movie night"])
    }

    func testAStationsOwnPlaylistTakesRulesThroughItsOwner() async throws {
        let path = "/profiles/\(UID.n(1))/playlists/\(UID.n(3))/rules"
        transport.routes["PUT \(path)"] = (.ok, #"{"match":"all","groups":[]}"#)
        let station: Station = Fixtures.decode(Fixtures.station(5, "Late show", kind: "tv"))
        let rules = editor(.station(station))
        XCTAssertFalse(rules.namesList)
        XCTAssertEqual(rules.fields, SmartField.fields(.playlist(.tv)))
        await rules.load()
        XCTAssertTrue(rules.ready, "a station not yet smart starts from one row")
        rules.groups[0].conditions[0].value = "Pilot"
        let saved = await rules.save()
        XCTAssertTrue(saved, "\(rules.error ?? "")")
        XCTAssertEqual(transport.paths(.put), [path])
        XCTAssertEqual(transport.paths(.get), [], "nothing to read")
    }
}
