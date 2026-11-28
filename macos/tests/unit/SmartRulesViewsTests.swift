import AppKit
import RabbitEarsAPI
import SwiftUI
import Vision
import XCTest

@testable import RabbitEarsKit

/// The name and rules sheets and a smart playlist's page, drawn offscreen and read back as the text they show.
@MainActor
final class SmartRulesViewsTests: XCTestCase {
    private var synced: SyncedReplica!
    private var window: NSWindow?

    override func setUp() async throws {
        synced = try SyncedReplica { db in
            try db.account(1, "Avery")
            try db.playlist(4, "Movie night")
        }
    }

    override func tearDown() async throws {
        window?.close()
        synced.remove()
    }

    func testTheSheetShowsEachRowAndTheOwnersNoteOnlyForAPersonalField() async throws {
        let editor = SmartRulesEditor(
            target: .newPlaylist(name: "Late ones", kind: .movies), client: synced.client, queue: synced.queue,
            profileId: 1)
        editor.groups[0].conditions[0].op = .contains
        editor.addCondition(to: editor.groups[0].id)
        editor.groups[0].conditions[1].field = .runtime
        editor.groups[0].conditions[1].op = .ge
        try await show(SmartRulesSheet(editor: editor))
        let text = try await shown()
        for expected in [
            "New smart playlist", "Match", "of these conditions", "Title", "contains", "Runtime",
            "at least", "min", "+ Condition", "+ Group", "Cancel", "Save",
        ] {
            // Recognition reads a control's glyph beside its text, as "min -".
            XCTAssertTrue(text.contains { $0.contains(expected) }, "\(expected) in \(text)")
        }
        XCTAssertFalse(text.contains { $0.contains("owner") }, "\(text)")
        XCTAssertFalse(text.contains("of:"), "one group reads as its conditions")
        XCTAssertFalse(text.contains("Name") || text.contains("Movies"), "the name sheet asked both: \(text)")

        editor.groups[0].conditions[1].field = .watched
        try await settle()
        let personal = try await shown()
        XCTAssertTrue(personal.contains { $0.hasPrefix("Yes") }, "\(personal)")
        XCTAssertTrue(personal.contains { $0.contains("the owner's") }, "\(personal)")

        editor.addGroup()
        try await settle()
        let grouped = try await shown()
        XCTAssertTrue(grouped.contains("of these groups"), "\(grouped)")
        XCTAssertTrue(grouped.contains("of:"), "\(grouped)")
    }

    func testACollectionsSheetNamesNoKindAndAStationsNoName() async throws {
        let collection = SmartRulesEditor(
            target: .newCollection(name: "Short ones"), client: synced.client, queue: synced.queue, profileId: 1)
        try await show(SmartRulesSheet(editor: collection))
        let text = try await shown()
        XCTAssertTrue(text.contains("New smart collection"), "\(text)")
        XCTAssertFalse(text.contains("Movies") || text.contains("Music"), "\(text)")

        let station: Station = Fixtures.decode(Fixtures.station(5, "Late show", kind: "tv"))
        let rules = SmartRulesEditor(
            target: .station(station), client: synced.client, queue: synced.queue, profileId: 1)
        try await show(SmartRulesSheet(editor: rules))
        let stationText = try await shown()
        XCTAssertTrue(stationText.contains("Station rules"), "\(stationText)")
        XCTAssertFalse(stationText.contains("Name"), "\(stationText)")
    }

    func testANewListsNameSheetOffersSmartOffByDefaultAndARenameDoesNot() async throws {
        let app = try await signedIn()
        let playlists = synced.playlists()
        let collections = synced.collections()
        try await show(
            PlaylistNameSheet(request: PlaylistNameRequest(kind: .tv)).environment(playlists).environment(Browser())
                .environment(app))
        let text = try await shown()
        for expected in ["New playlist", "Smart", "Fills itself from rules you set.", "Create"] {
            XCTAssertTrue(text.contains(expected), "\(expected) in \(text)")
        }
        try await show(
            CollectionNameSheet(request: CollectionNameRequest()).environment(collections).environment(Browser())
                .environment(app))
        let collection = try await shown()
        XCTAssertTrue(collection.contains("Smart") && collection.contains("New collection"), "\(collection)")

        await playlists.load()
        let renaming = PlaylistNameRequest(renaming: try XCTUnwrap(playlists.playlists.first))
        try await show(
            PlaylistNameSheet(request: renaming).environment(playlists).environment(Browser()).environment(app))
        let rename = try await shown()
        XCTAssertTrue(rename.contains("Rename playlist"), "\(rename)")
        XCTAssertFalse(rename.contains("Smart"), "\(rename)")
    }

    func testCreateWithSmartOnHandsTheNameAndKindToTheRuleEditor() throws {
        let request = PlaylistNameRequest(kind: .tv)
        XCTAssertNil(request.smartRules(named: "Late ones", smart: false), "off makes the playlist at once")
        let playlist = try XCTUnwrap(request.smartRules(named: "Late ones", smart: true))
        guard case .newPlaylist(let name, let kind) = playlist.target else { return XCTFail("a new playlist's rules") }
        XCTAssertEqual(name, "Late ones")
        XCTAssertEqual(kind, .tv)
        XCTAssertNil(PlaylistNameRequest(kind: .tv, itemId: UID.n(9)).smartRules(named: "x", smart: true))
        XCTAssertNil(request.smartRules(named: "  ", smart: true), "Return in a blank name goes nowhere")

        XCTAssertNil(CollectionNameRequest().smartRules(named: "Short ones", smart: false))
        let collection = try XCTUnwrap(CollectionNameRequest().smartRules(named: "Short ones", smart: true))
        guard case .newCollection(let named) = collection.target else { return XCTFail("a new collection's rules") }
        XCTAssertEqual(named, "Short ones")
        XCTAssertNil(CollectionNameRequest(movieId: UID.n(9)).smartRules(named: "x", smart: true))
    }

    func testASmartPlaylistsPageCarriesTheBadgeByItsName() async throws {
        let playlists = synced.playlists()
        await playlists.load()
        playlists.playlists = playlists.playlists.map { playlist in
            var playlist = playlist
            playlist.smart = true
            return playlist
        }
        let app = try await signedIn()
        try await show(PlaylistScreen(id: 4).environment(playlists).environment(Browser()).environment(app))
        let text = try await shown()
        XCTAssertTrue(text.contains("Movie night"), "\(text)")
        XCTAssertTrue(text.contains { $0.hasSuffix("Smart") }, "\(text)")
    }

    // MARK: Drawing and reading back

    private func signedIn() async throws -> AppModel {
        let transport = RoutingTransport([
            "POST /auth/sign-in": (.created, #"{"token":"tok-1","me":\#(Fixtures.me)}"#), "GET /me": (.ok, Fixtures.me),
        ])
        let app = AppModel(
            store: MemoryCredentialStore(), deviceName: "Test Mac", transport: transport,
            replicaDirectory: Fixtures.replicas)
        try await app.signIn(server: "127.0.0.1", email: "a@example.test", password: "x")
        return app
    }

    private func show(_ view: some View) async throws {
        window?.close()
        let controller = NSHostingController(rootView: AnyView(view))
        controller.sizingOptions = []
        let window = NSWindow(
            contentRect: .init(x: 0, y: 0, width: 900, height: 700),
            styleMask: [.titled, .resizable, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.setContentSize(.init(width: 900, height: 700))
        self.window = window
        try await settle()
    }

    private func shown() async throws -> [String] {
        try await TextRecognition.require()
        let view = try XCTUnwrap(window?.contentView)
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        let observations = try await request.perform(on: try XCTUnwrap(bitmap.cgImage))
        // Recognition reads an ellipsis as three periods.
        return observations.compactMap {
            $0.topCandidates(1).first?.string.replacingOccurrences(of: "...", with: "…")
        }
    }

    private func settle() async throws { try await Task.sleep(for: .seconds(1)) }
}
