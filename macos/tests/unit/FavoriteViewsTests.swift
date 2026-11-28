import AppKit
import GRDB
import RabbitEarsAPI
import SwiftUI
import Vision
import XCTest

@testable import RabbitEarsKit

/// The sidebar's Favorites and the star beside Play, drawn offscreen and read back.
@MainActor
final class FavoriteViewsTests: XCTestCase {
    private var model: AppModel!
    private var replica: Replica!
    private var fixture: ReplicaFixture!
    private var window: NSWindow?

    /// Avery (1) with Dune (20), and Nude (1) on In Rainbows (50) by Radiohead (40).
    override func setUp() async throws {
        let transport = RoutingTransport([
            "POST /auth/sign-in": (.created, Fixtures.signedIn),
            "GET /me": (.ok, Fixtures.me),
            "POST /profiles/\(UID.n(1))/unlock": (.noContent, ""),
        ])
        model = AppModel(
            store: MemoryCredentialStore(), deviceName: "Test Mac", transport: transport,
            replicaDirectory: Fixtures.replicas)
        try await model.signIn(server: "127.0.0.1", email: "a@example.test", password: "x")
        try await model.choose(model.profiles[0])
        fixture = ReplicaFixture()
        replica = try XCTUnwrap(model.sync).replica
        try replica.adopt(
            fixture.v1File { db in
                try db.account(1, "Avery")
                try db.item(20, "movie", "Dune")
                try db.artist(40, "Radiohead")
                try db.album(50, "In Rainbows", artist: 40)
                try db.song(1, "Nude", album: 50, track: 1)
            })
    }

    override func tearDown() async throws {
        window?.close()
        fixture.remove()
    }

    func testTheSidebarListsOnlyStarredKindsBetweenTheLibrariesAndPlaylists() async throws {
        try await show(MainView(nowPlaying: SystemNowPlayingCenter { _ in nil }).environment(MainWindowState()))
        var sidebar = try await sidebarText()
        XCTAssertFalse(sidebar.contains { $0.hasPrefix("Favo") }, "no stars, no section: \(sidebar)")
        XCTAssertTrue(sidebar.contains("Playlists"), "\(sidebar)")

        try await star([20, 1])
        sidebar = try await sidebarText()
        // Recognition can misread the small header, as "Favontes.".
        let favorites = try XCTUnwrap(sidebar.firstIndex { $0.hasPrefix("Favo") }, "\(sidebar)")
        let playlists = try XCTUnwrap(sidebar.firstIndex(of: "Playlists"), "\(sidebar)")
        XCTAssertEqual(Array(sidebar[(favorites + 1)...playlists]), ["Movies", "Songs", "Playlists"])
        XCTAssertTrue(sidebar[favorites - 1].contains("Stations"), "after the last library: \(sidebar)")

        try await unstar([20, 1])
        sidebar = try await sidebarText()
        XCTAssertFalse(sidebar.contains { $0.hasPrefix("Favo") }, "the last star gone: \(sidebar)")
    }

    func testTheStarFillsAmberOnceTheTitleIsStarred() async throws {
        try await show(FavoriteButton(id: 20))
        XCTAssertFalse(try showsAmber(), "an outline star")
        try await star([20])
        XCTAssertTrue(try showsAmber(), "a filled amber star")
    }

    // MARK: Stars and drawing

    private func star(_ ids: [UID]) async throws {
        try await replica.write { db in
            for id in ids {
                try db.execute(
                    sql: "INSERT INTO favorite VALUES (?, ?, ?)", arguments: [1 as UID, id, 1_800_000_000_000])
            }
        }
        await model.loadFavorites()
        try await settle()
    }

    private func unstar(_ ids: [UID]) async throws {
        try await replica.write { db in
            for id in ids { try db.execute(sql: "DELETE FROM favorite WHERE item_id = ?", arguments: [id]) }
        }
        await model.loadFavorites()
        try await settle()
    }

    private func show(_ view: some View) async throws {
        let controller = NSHostingController(rootView: AnyView(view.environment(model)))
        controller.sizingOptions = []
        let window = NSWindow(
            contentRect: .init(x: 0, y: 0, width: 1200, height: 760),
            styleMask: [.titled, .resizable, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.setContentSize(.init(width: 1200, height: 760))
        self.window = window
        try await settle()
    }

    /// The sidebar column's lines, top to bottom.
    private func sidebarText() async throws -> [String] {
        let view = try XCTUnwrap(window?.contentView)
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        let observations = try await request.perform(on: try XCTUnwrap(bitmap.cgImage))
        // The sidebar is 210 points of the window's 1200.
        return
            observations
            .filter { $0.boundingBox.cgRect.maxX < 200.0 / 1200 }
            .sorted { $0.boundingBox.cgRect.midY > $1.boundingBox.cgRect.midY }
            .compactMap { $0.topCandidates(1).first?.string }
    }

    /// Whether any pixel is Theme.amber's; the button's own colors are white and gray.
    private func showsAmber() throws -> Bool {
        let view = try XCTUnwrap(window?.contentView)
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        for column in 0..<bitmap.pixelsWide {
            for row in 0..<bitmap.pixelsHigh {
                guard let color = bitmap.colorAt(x: column, y: row)?.usingColorSpace(.sRGB) else { continue }
                if color.redComponent > 0.85, (0.6...0.8).contains(color.greenComponent), color.blueComponent < 0.35 {
                    return true
                }
            }
        }
        return false
    }

    private func settle() async throws { try await Task.sleep(for: .seconds(1)) }
}
