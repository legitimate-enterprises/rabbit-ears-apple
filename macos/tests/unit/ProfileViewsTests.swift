import AppKit
import RabbitEarsAPI
import SwiftUI
import Vision
import XCTest

@testable import RabbitEarsKit

/// Who's watching and Preferences, drawn offscreen and read back as the text they show.
@MainActor
final class ProfileViewsTests: XCTestCase {
    private var transport: RoutingTransport!
    private var model: AppModel!
    private var window: NSWindow?
    /// Removed in tearDown: XCTest reports the error a `defer` swallows in place of one thrown past it.
    private var fixture: ReplicaFixture?

    override func setUp() async throws {
        let admin = Fixtures.adult.replacingOccurrences(of: #""isAdmin":false"#, with: #""isAdmin":true"#)
        let me = Fixtures.me.replacingOccurrences(of: Fixtures.adult, with: admin)
        transport = RoutingTransport([
            "POST /auth/sign-in": (.created, #"{"token":"tok-1","me":\#(me)}"#),
            "GET /me": (.ok, me),
            "POST /me/lock": (.noContent, ""),
            "POST /profiles/\(UID.n(1))/unlock": (.noContent, ""),
            "POST /profiles/\(UID.n(2))/unlock": (.noContent, ""),
        ])
        let downloads = DownloadStore(directory: Fixtures.replicas, downloader: FakeDownloader(), facts: { .decoder })
        model = AppModel(
            store: MemoryCredentialStore(), deviceName: "Test Mac", transport: transport, downloads: downloads,
            replicaDirectory: Fixtures.replicas)
        try await model.signIn(server: "127.0.0.1", email: "a@example.test", password: "x")
    }

    override func tearDown() async throws {
        window?.close()
        fixture?.remove()
        fixture = nil
    }

    func testWhoIsWatchingOnlyPicksAProfileEvenForTheOwner() async throws {
        XCTAssertTrue(model.canManageHousehold)
        XCTAssertTrue(model.isOwner)
        try await show(WhosWatchingView(), height: 600)
        let text = try await shown().map(\.text)
        XCTAssertTrue(text.contains("Avery"), "\(text)")
        XCTAssertTrue(text.contains("Robin"), "\(text)")
        XCTAssertFalse(text.contains { $0.contains("Add") }, "\(text)")
    }

    func testPreferencesHoldDownloadsHouseholdAndAccountWithOneDone() async throws {
        try await model.choose(model.profiles[0])
        try await show(PreferencesSheet(), height: 900)
        let text = try await everything()
        for expected in [
            "Autoplay", "Downloads", "Prefer downloads", "Wi-Fi only", "Household", "Add a kid…", "Add an adult…",
            "Manage household…", "Account", "Password…", "Admin", "Delete account…", "Done",
        ] {
            XCTAssertTrue(text.contains(expected), "\(expected) in \(text)")
        }
        for gone in ["Save", "Cancel", "Downloads…"] {
            XCTAssertFalse(text.contains(gone), "\(gone) in \(text)")
        }
    }

    func testAnAdultsPreferencesEndWithFriendsCountedFromTheReplica() async throws {
        try await model.choose(model.profiles[0])
        let fixture = ReplicaFixture()
        self.fixture = fixture
        try XCTUnwrap(model.sync).replica.adopt(
            fixture.v1File { db in
                try db.account(1, "Avery")
                try db.friend(10, "Bea")
                try db.friend(11, "Cal")
                try db.friendship(1, 10)
                try db.requestIn(40, from: 11, to: 1, created: "2026-03-01T00:00:00Z")
            })
        try await show(PreferencesSheet(), height: 900)
        let text = try await everything()
        for expected in ["Friends", "Friends…", "1 friend", "1 request"] {
            XCTAssertTrue(text.contains(expected), "\(expected) in \(text)")
        }
        let account = try XCTUnwrap(text.firstIndex(of: "Account"))
        XCTAssertGreaterThan(try XCTUnwrap(text.firstIndex(of: "Friends")), account, "after Account")
    }

    func testAKidsPreferencesHaveNoFriends() async throws {
        try await model.choose(model.profiles[1], pin: "1234")
        try await show(PreferencesSheet(), height: 900)
        let text = try await everything()
        XCTAssertTrue(text.contains("Autoplay"), "\(text)")
        XCTAssertFalse(text.contains { $0.contains("Friend") || $0.contains("request") }, "\(text)")
    }

    func testAnAdultWhoIsNotTheOwnerOrAnAdminCannotAddAnAdult() async throws {
        let other = Fixtures.me.replacingOccurrences(
            of: #""adultId":"\#(UID.n(1))""#, with: #""adultId":"\#(UID.n(3))""#)
        transport.routes["GET /me"] = (.ok, other)
        try await model.choose(model.profiles[0])
        await model.reload()
        XCTAssertFalse(model.isOwner)
        try await show(PreferencesSheet(), height: 900)
        let text = try await everything()
        XCTAssertTrue(text.contains("Add a kid…"), "\(text)")
        XCTAssertFalse(text.contains("Add an adult…"), "\(text)")
        XCTAssertFalse(text.contains("Admin"), "\(text)")
    }

    func testAPreferenceSavesAsItIsChanged() async throws {
        try await model.choose(model.profiles[0])
        let fixture = ReplicaFixture()
        self.fixture = fixture
        try XCTUnwrap(model.sync).replica.adopt(fixture.v1File { db in try db.account(1, "Avery") })
        try await show(PreferencesSheet(), height: 900)
        XCTAssertNotEqual(model.activeProfile?.autoplay, false)
        let lines = try await shown()
        let autoplay = try XCTUnwrap(lines.first { $0.text == "Autoplay" }, "\(lines.map(\.text))")
        let view = try XCTUnwrap(window?.contentView)
        func distance(_ control: NSSwitch) -> CGFloat {
            let center = view.convert(NSPoint(x: control.bounds.midX, y: control.bounds.midY), from: control)
            return abs(center.y - autoplay.center.y)
        }
        // Its own switch, the one level with the label.
        let toggle = try XCTUnwrap(switches(in: view).min { distance($0) < distance($1) })
        toggle.performClick(nil)
        try await settle()
        XCTAssertEqual(model.activeProfile?.autoplay, false, "saved with no Save to press")
    }

    func testThePreferencesSheetFitsTheSmallestWindowAndScrollsTheRest() async throws {
        try await model.choose(model.profiles[0])
        try await show(PreferencesSheet(), height: 900)
        let size = try XCTUnwrap(window?.contentView?.fittingSize)
        // The main window's content is at least 600 points tall.
        XCTAssertLessThanOrEqual(size.height, 600)
        let scroll = try XCTUnwrap(scrollView())
        XCTAssertGreaterThan(scroll.documentView?.frame.height ?? 0, scroll.contentView.bounds.height)
    }

    func testPreferencesAreOnlyForAnAdultBrowsing() async throws {
        XCTAssertFalse(model.offersPreferences, "at Who's watching")
        try await model.choose(model.profiles[0])
        XCTAssertTrue(model.offersPreferences)
        await model.switchProfile()
        try await model.choose(model.profiles[1], pin: "1234")
        XCTAssertFalse(model.offersPreferences, "for a kid")
        await model.signOut()
        XCTAssertFalse(model.offersPreferences, "signed out")
    }

    func testTheAppMenusPreferencesOpenTheProfileMenusSheet() async throws {
        try await model.choose(model.profiles[0])
        let app = MainWindowState()
        try await show(ProfileMenu().environment(app), height: 600)
        let before = Set(NSApp.windows.map(ObjectIdentifier.init))
        // As the app menu's Preferences… does.
        app.showingPreferences = true
        try await settle()
        // Offscreen, the sheet has its own window, not yet attached to the one it is presented on.
        let sheet = try XCTUnwrap(NSApp.windows.first { !before.contains(ObjectIdentifier($0)) })
        defer { sheet.close() }
        let text = try await shown(in: sheet).map(\.text)
        XCTAssertTrue(text.contains("Autoplay"), "\(text)")
    }

    // MARK: Drawing and reading back

    private struct Line {
        let text: String
        /// In the hosting view's coordinates.
        let center: CGPoint
    }

    private func show(_ view: some View, height: CGFloat) async throws {
        let controller = NSHostingController(rootView: AnyView(view.environment(model)))
        controller.sizingOptions = []
        let window = NSWindow(
            contentRect: .init(x: 0, y: 0, width: 900, height: height),
            styleMask: [.titled, .resizable, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.setContentSize(.init(width: 900, height: height))
        self.window = window
        try await settle()
    }

    /// The text of every part of a scrolling view, scrolled through from the top.
    private func everything() async throws -> [String] {
        var text = try await shown().map(\.text)
        if let scroll = scrollView(), let document = scroll.documentView {
            var top: CGFloat = 0
            while top + scroll.contentView.bounds.height < document.frame.height {
                top += scroll.contentView.bounds.height / 2
                scroll.contentView.scroll(to: .init(x: 0, y: top))
                scroll.reflectScrolledClipView(scroll.contentView)
                try await settle()
                text += try await shown().map(\.text)
            }
        }
        return text
    }

    private func shown(in shownWindow: NSWindow? = nil) async throws -> [Line] {
        try await TextRecognition.require()
        let view = try XCTUnwrap((shownWindow ?? window)?.contentView)
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        let observations = try await request.perform(on: try XCTUnwrap(bitmap.cgImage))
        return observations.compactMap { observation in
            // Recognition reads an ellipsis as three periods.
            guard let text = observation.topCandidates(1).first?.string.replacingOccurrences(of: "...", with: "…")
            else { return nil }
            let box = observation.boundingBox.cgRect
            let fromTop = view.isFlipped ? 1 - box.midY : box.midY
            return Line(text: text, center: .init(x: box.midX * view.bounds.width, y: fromTop * view.bounds.height))
        }
    }

    private func scrollView() -> NSScrollView? {
        func find(_ view: NSView) -> NSScrollView? {
            (view as? NSScrollView) ?? view.subviews.lazy.compactMap(find).first
        }
        return window?.contentView.flatMap(find)
    }

    private func switches(in view: NSView) -> [NSSwitch] {
        ((view as? NSSwitch).map { [$0] } ?? []) + view.subviews.flatMap(switches)
    }

    private func settle() async throws { try await Task.sleep(for: .seconds(1)) }
}
