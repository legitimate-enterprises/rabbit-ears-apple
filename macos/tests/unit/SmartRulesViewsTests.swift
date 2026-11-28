import AppKit
import RabbitEarsAPI
import SwiftUI
import Vision
import XCTest

@testable import RabbitEarsKit

/// The rules sheet and a smart playlist's page, drawn offscreen and read back as the text they show.
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
            target: .newPlaylist(.movies), client: synced.client, queue: synced.queue, profileId: 1)
        editor.groups[0].conditions[0].op = .contains
        editor.addCondition(to: editor.groups[0].id)
        editor.groups[0].conditions[1].field = .runtime
        editor.groups[0].conditions[1].op = .ge
        try await show(SmartRulesSheet(editor: editor))
        let text = try await shown()
        for expected in [
            "New smart playlist", "Name", "Movies", "Match", "of these conditions", "Title", "contains", "Runtime",
            "at least", "min", "+ Condition", "+ Group", "Cancel", "Save",
        ] {
            // Recognition reads a control's glyph beside its text, as "min -".
            XCTAssertTrue(text.contains { $0.contains(expected) }, "\(expected) in \(text)")
        }
        XCTAssertFalse(text.contains { $0.contains("owner") }, "\(text)")
        XCTAssertFalse(text.contains("of:"), "one group reads as its conditions")

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
            target: .newCollection, client: synced.client, queue: synced.queue, profileId: 1)
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

    func testASmartPlaylistsPageCarriesTheBadgeByItsName() async throws {
        let playlists = synced.playlists()
        await playlists.load()
        playlists.playlists = playlists.playlists.map { playlist in
            var playlist = playlist
            playlist.smart = true
            return playlist
        }
        let transport = RoutingTransport([
            "POST /auth/sign-in": (.created, #"{"token":"tok-1","me":\#(Fixtures.me)}"#), "GET /me": (.ok, Fixtures.me),
        ])
        let app = AppModel(
            store: MemoryCredentialStore(), deviceName: "Test Mac", transport: transport,
            replicaDirectory: Fixtures.replicas)
        try await app.signIn(server: "127.0.0.1", email: "a@example.test", password: "x")
        try await show(PlaylistScreen(id: 4).environment(playlists).environment(Browser()).environment(app))
        let text = try await shown()
        XCTAssertTrue(text.contains("Movie night"), "\(text)")
        XCTAssertTrue(text.contains { $0.hasSuffix("Smart") }, "\(text)")
    }

    // MARK: Drawing and reading back

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
