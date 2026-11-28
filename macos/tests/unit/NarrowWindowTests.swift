import AppKit
import RabbitEarsAPI
import SwiftUI
import XCTest

@testable import RabbitEarsKit

/// The main window at its smallest, drawn offscreen and measured without reading its text.
@MainActor
final class NarrowWindowTests: XCTestCase {
    private var model: AppModel!
    private var fixture: ReplicaFixture!
    private var window: NSWindow?
    private let browser = Browser()
    private var player: MusicPlayer?

    /// A library of each kind; three movies part watched, so Home has its hero and the column beside it;
    /// a show with an episode, and a song.
    override func setUp() async throws {
        let transport = RoutingTransport([
            "POST /auth/sign-in": (.created, Fixtures.signedIn),
            "GET /me": (.ok, Fixtures.me),
            "POST /profiles/\(UID.n(1))/unlock": (.noContent, ""),
            "POST /playback/sessions": (.created, Fixtures.audioStream(1)),
        ])
        model = AppModel(
            store: MemoryCredentialStore(), deviceName: "Test Mac", transport: transport,
            replicaDirectory: Fixtures.replicas)
        try await model.signIn(server: "127.0.0.1", email: "a@example.test", password: "x")
        try await model.choose(model.profiles[0])
        fixture = ReplicaFixture()
        try XCTUnwrap(model.sync).replica.adopt(
            fixture.v1File { db in
                try db.account(1, "Avery")
                for (id, kind) in [(1, "movies"), (2, "tv"), (3, "music"), (4, "youtube")] as [(UID, String)] {
                    try db.library(id, kind)
                }
                let genres: [(UID, String)] = [(1, "Science Fiction"), (2, "Drama"), (3, "Thriller")]
                let movies: [(UID, String)] = [(20, "Dune"), (21, "Arrival"), (22, "Heat")]
                for (day, (id, title)) in movies.enumerated() {
                    try db.item(id, "movie", title, runtime: 120, rating: "PG-13", year: 2021, genres: genres)
                    try db.watch(id, for: 1, position: 1_800_000, played: "2026-03-0\(day + 1)T00:00:00Z")
                }
                try db.item(30, "show", "Fargo", year: 2014, genres: genres, library: 2)
                try db.item(31, "season", "Season 1", parent: 30, season: 1, library: 2)
                try db.item(
                    32, "episode", "The Crocodile's Dilemma", parent: 31, season: 1, episode: 1, runtime: 68,
                    library: 2)
                try db.artist(40, "Radiohead")
                try db.album(50, "In Rainbows", artist: 40, year: 2007)
                try db.song(1, "15 Step", album: 50, track: 1)
            })
    }

    override func tearDown() async throws {
        window?.close()
        fixture.remove()
    }

    func testEverySectionFitsTheSmallestWindowWhateverTheSidebarsWidth() async throws {
        try await showMain()
        for (row, name) in ["home", "tv", "movies", "music", "youtube", "stations"].enumerated() {
            try XCTUnwrap(find(NSTableView.self)).selectRowIndexes([row], byExtendingSelection: false)
            try await assertFits(name)
        }
    }

    func testEveryDetailsPageFitsTheSmallestWindowWhateverTheSidebarsWidth() async throws {
        try await showMain()
        for (route, name) in [
            (Route.item(20), "movie"), (.item(30), "show"), (.item(31), "season"), (.item(32), "episode"),
            (.album(50), "album"), (.artist(40), "artist"),
        ] {
            browser.open(route)
            try await assertFits(name)
        }
    }

    func testMusicPlayingFitsTheSmallestWindowWhateverTheSidebarsWidth() async throws {
        try await showMain()
        let detail = try await XCTUnwrap(model.musicModel).album(50)
        try await XCTUnwrap(player).play(detail.songs, source: detail.album.title)
        try await assertFits("mini-player")
        browser.open(.nowPlaying)
        try await assertFits("now-playing")
    }

    func testTheSmallestWindowFitsWithTheSidebarCollapsed() async throws {
        try await showMain()
        let split = try XCTUnwrap(find(NSSplitView.self))
        try XCTUnwrap(split.delegate as? NSSplitViewController).toggleSidebar(nil)
        try await settle()
        try assertInside("collapsed")
    }

    /// Squeezed, a button or chip keeps its whole label on one line rather than wrapping it letter by letter.
    func testButtonsAndChipsKeepTheirLabelsWhole() {
        let views: [(String, AnyView)] = [
            ("secondary", AnyView(Button("Select") {}.buttonStyle(SecondaryButtonStyle()))),
            ("primary", AnyView(Button("Resume") {}.buttonStyle(PrimaryButtonStyle()))),
            ("chip", AnyView(Chip(title: "In progress", picked: false) {})),
        ]
        for (name, view) in views {
            let host = NSHostingController(rootView: view)
            let ideal = host.sizeThatFits(in: .init(width: 10_000, height: 10_000))
            let squeezed = host.sizeThatFits(in: .init(width: 10, height: 10_000))
            XCTAssertEqual(squeezed, ideal, name)
        }
    }

    // MARK: Drawing and measuring

    /// Browsing at the main window's smallest size, once the profile's libraries have loaded.
    private func showMain() async throws {
        let controller = NSHostingController(
            rootView: AnyView(
                MainView(
                    nowPlaying: SystemNowPlayingCenter { _ in nil }, entered: { self.player = $0 }, browser: browser
                )
                .environment(MainWindowState()).environment(model)))
        controller.sizingOptions = []
        let window = NSWindow(
            contentRect: .init(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .resizable, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.setContentSize(.init(width: 900, height: 600))
        self.window = window
        for _ in 0..<40 where model.librarySections.count < 4 { try await Task.sleep(for: .milliseconds(250)) }
        XCTAssertEqual(model.librarySections.count, 4)
        try await settle()
    }

    /// At the sidebar's own width and then dragged as wide as it goes.
    private func assertFits(_ name: String, line: UInt = #line) async throws {
        let split = try XCTUnwrap(find(NSSplitView.self))
        split.setPosition(210, ofDividerAt: 0)
        try await settle()
        try assertInside(name, line: line)
        split.setPosition(400, ofDividerAt: 0)
        try await settle()
        try assertInside("\(name), wide sidebar", line: line)
    }

    /// Wider than the window, the split view slides the sidebar out past the window's left edge.
    private func assertInside(_ name: String, line: UInt = #line) throws {
        let content = try XCTUnwrap(window?.contentView)
        let split = try XCTUnwrap(find(NSSplitView.self))
        let frame = split.convert(split.bounds, to: content)
        let message = "\(name): \(frame) in \(content.bounds)"
        XCTAssertGreaterThanOrEqual(frame.minX, 0, message, line: line)
        XCTAssertLessThanOrEqual(frame.maxX, content.bounds.maxX, message, line: line)
    }

    private func find<View: NSView>(_ type: View.Type) -> View? {
        func search(_ view: NSView) -> View? { (view as? View) ?? view.subviews.lazy.compactMap(search).first }
        return window?.contentView.flatMap(search)
    }

    private func settle() async throws { try await Task.sleep(for: .seconds(1)) }
}
