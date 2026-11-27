import AppKit
import RabbitEarsAPI
import RabbitEarsKit
import SwiftUI

enum SidebarSection: Hashable {
    case home, tv, movies, music, youtube, stations
    case playlist(UID)
    case station(UID)

    /// Every profile's libraries; the server filters what a kid sees in each.
    static let libraries: [SidebarSection] = [.home, .tv, .movies, .music, .youtube, .stations]
    /// Cmd-1 to Cmd-6, in this order.
    static let numbered: [SidebarSection] = [.home, .movies, .tv, .music, .youtube, .stations]

    /// The libraries a section lists; nil for a section that always shows.
    var library: LibrarySection? {
        switch self {
        case .tv: .tv
        case .movies: .movies
        case .music: .music
        case .youtube: .youtube
        default: nil
        }
    }

    var title: String {
        switch self {
        case .home: "Home"
        case .tv: "TV"
        case .movies: "Movies"
        case .music: "Music"
        case .youtube: "YouTube"
        case .stations: "Stations"
        case .playlist: "Playlist"
        case .station: "Station"
        }
    }

    var icon: String {
        switch self {
        case .home: "house"
        case .tv: "tv"
        case .movies: "film"
        case .music: "music.note"
        case .youtube: "play.rectangle"
        case .playlist: "music.note.list"
        case .station, .stations: "antenna.radiowaves.left.and.right"
        }
    }
}

enum Route: Hashable {
    case item(Item.ID)
    case person(Person.ID)
    case album(UID)
    case artist(UID)
    case nowPlaying
    case playlist(UID)
    case collection(UID)
    case occasion(ActiveOccasion)
    case channel(UID)
    case video(UID)
    case station(UID)
}

/// Navigation shared by every browsing view: the detail stack and what is playing.
@MainActor
@Observable
final class Browser: VideoBrowser {
    var history = NavigationHistory<Route>()
    var path: [Route] {
        get { history.path }
        set { history.path = newValue }
    }
    var playing: PlayRequest?
    /// Rises when playback ends or watch state changes, so lists show the new marks.
    var revision = 0
    var naming: PlaylistNameRequest?
    var deleting: Playlist?
    var sharing: Playlist?
    var imaging: ImageRequest?
    var namingCollection: CollectionNameRequest?
    var deletingCollection: MovieCollection?
    /// The movies or tv station playing in the player, in place of `playing`.
    var tuning: Station?
    var editingStation: StationEditRequest?
    /// The owner's station whose playlist just changed, for Reschedule now?
    var rescheduling: Station?
    /// A refusal to show in an alert.
    var alert: String?
    var showingShortcuts = false

    func open(_ item: Item) { path.append(.item(item.id)) }
    func replace(with item: Item) { path.replaceTop(with: .item(item.id)) }
    func open(person id: Person.ID) { path.append(.person(id)) }
    func open(_ route: Route) { path.append(route) }

    func play(_ video: YouTubeVideo, from positionMs: Int64? = nil, together: WatchTogetherModel? = nil) {
        guard together == nil || !watchesTogether(video.id) else { return }
        playing = PlayRequest(item: Item(video: video), positionMs: positionMs, together: together)
    }

    func play(_ queue: VideoQueue, from positionMs: Int64? = nil) {
        playing = PlayRequest(item: queue.current, editionId: queue.editionId, positionMs: positionMs, queue: queue)
    }
}

/// A page's name, for the window title and the back button of the page after it.
struct PageTitle: PreferenceKey {
    static let defaultValue: String? = nil
    static func reduce(value: inout String?, nextValue: () -> String?) { value = nextValue() ?? value }
}

extension View {
    func pageTitle(_ title: String) -> some View {
        navigationTitle(title).preference(key: PageTitle.self, value: title)
    }

    /// A pushed page: its back button stands in for the stack's, and its title is kept for the page after it.
    func page(_ route: Route, in browser: Browser, root: String) -> some View {
        navigationBarBackButtonHidden()
            .toolbar { ToolbarItem(placement: .navigation) { BackButton(root: root) } }
            .onPreferenceChange(PageTitle.self) { title in
                MainActor.assumeIsolated {
                    if let title, !title.isEmpty { browser.history.titles[route] = title }
                }
            }
    }
}

/// Back, labeled with the page it returns to. Forward is the Go menu's,
/// Cmd-] and mouse button 5.
struct BackButton: View {
    @Environment(Browser.self) private var browser
    let root: String

    var body: some View {
        if let title = browser.history.backTitle(root: root) {
            Button {
                browser.history.back()
            } label: {
                Label {
                    Text(title).lineLimit(1).truncationMode(.tail)
                        .frame(maxWidth: 180, alignment: .leading).fixedSize(horizontal: true, vertical: false)
                } icon: {
                    Image(systemName: "chevron.left")
                }
                .labelStyle(.titleAndIcon)
            }
            .help("Back to \(title)")
            .accessibilityLabel("Back to \(title)")
        }
    }
}

/// What the menu bar's commands reach in the window's browsing.
struct Navigator {
    let browser: Browser
    let show: (SidebarSection) -> Void
    let shows: (SidebarSection) -> Bool
    let search: () -> Void
}

extension FocusedValues {
    @Entry var navigator: Navigator?
}

extension View {
    func navigation(_ navigator: Navigator) -> some View {
        modifier(HistoryGestures(browser: navigator.browser))
            .focusedSceneValue(\.navigator, navigator)
            .sheet(isPresented: Bindable(navigator.browser).showingShortcuts) { ShortcutsSheet() }
    }
}

struct NavigationCommands: Commands {
    @FocusedValue(\.navigator) private var navigator
    /// A player over the window takes no navigation.
    private var browsing: Navigator? {
        navigator.flatMap { $0.browser.playing == nil && $0.browser.tuning == nil ? $0 : nil }
    }

    var body: some Commands {
        // Search stands in for Find, whose Cmd-F it takes.
        CommandGroup(replacing: .textEditing) {
            Button("Search") { browsing?.search() }.keyboardShortcut("f").disabled(browsing == nil)
        }
        CommandMenu("Go") {
            Button("Back") { browsing?.browser.history.back() }.keyboardShortcut("[")
                .disabled(browsing?.browser.history.canGoBack != true)
            Button("Forward") { browsing?.browser.history.forward() }.keyboardShortcut("]")
                .disabled(browsing?.browser.history.canGoForward != true)
            Divider()
            ForEach(Array(SidebarSection.numbered.enumerated()), id: \.offset) { index, section in
                Button(section.title) { browsing?.show(section) }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")))
                    .disabled(browsing?.shows(section) != true)
            }
        }
        CommandGroup(after: .help) {
            Button("Keyboard Shortcuts") { navigator?.browser.showingShortcuts = true }.disabled(navigator == nil)
        }
    }
}

struct ShortcutsSheet: View {
    @Environment(\.dismiss) private var dismiss
    private static let groups: [(String, [(String, String)])] = [
        (
            "Anywhere",
            [
                ("⌘F", "Search"), ("⌘[", "Back"), ("⌘]", "Forward"), ("⌘1", "Home"), ("⌘2", "Movies"),
                ("⌘3", "TV"), ("⌘4", "Music"), ("⌘5", "YouTube"), ("⌘6", "Stations"), ("?", "Keyboard shortcuts"),
            ]
        ),
        (
            "Player",
            [
                ("Space", "Play or pause"), ("← →", "Back or ahead 10 seconds"), ("↑ ↓", "Volume"),
                ("F", "Full screen"), ("M", "Mute"), ("C", "Next subtitles"), ("Esc", "Close the player"),
            ]
        ),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Keyboard shortcuts").font(.system(size: 17, weight: .bold))
            ForEach(Self.groups, id: \.0) { group, rows in
                VStack(alignment: .leading, spacing: 6) {
                    Heading(text: group).foregroundStyle(Theme.secondary)
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                        ForEach(rows, id: \.0) { key, does in
                            GridRow {
                                Text(key).monospaced()
                                Text(does)
                            }
                        }
                    }
                }
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 360)
        .onExitCommand { dismiss() }
    }
}

/// Mouse buttons 4 and 5 and trackpad swipes go back and forward, and "?"
/// opens the shortcuts sheet, while the window's browsing shows. A local
/// monitor sees each event before any view does, so no view can take it.
struct HistoryGestures: ViewModifier {
    let browser: Browser
    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .onAppear {
                guard monitor == nil else { return }
                monitor = NSEvent.addLocalMonitorForEvents(
                    matching: [.otherMouseDown, .swipe, .scrollWheel, .keyDown]
                ) { event in
                    // Local monitors run on the main thread, with the event.
                    nonisolated(unsafe) let event = event
                    return MainActor.assumeIsolated { handled(event) } ? nil : event
                }
            }
            .onDisappear {
                if let monitor { NSEvent.removeMonitor(monitor) }
                monitor = nil
            }
    }

    /// Whether the event was taken, so goes no further. A player over the
    /// window has hidden the toolbar and takes no history gestures.
    private func handled(_ event: NSEvent) -> Bool {
        guard browser.playing == nil, browser.tuning == nil else { return false }
        if event.type == .keyDown { return asksForShortcuts(event) }
        if let step = HistoryStep(event) {
            browser.history.take(step)
            return true
        }
        if event.type == .scrollWheel { track(event) }
        return false
    }

    /// "?" with no command key, unless it is typed into a text field.
    private func asksForShortcuts(_ event: NSEvent) -> Bool {
        guard event.characters == "?", event.modifierFlags.isDisjoint(with: [.command, .control, .option]),
            !(event.window?.firstResponder is NSText), !browser.showingShortcuts
        else { return false }
        browser.showingShortcuts = true
        return true
    }

    /// Two fingers sideways, as Safari takes them, unless what is under the
    /// pointer scrolls sideways itself, as a strip of tiles does.
    private func track(_ event: NSEvent) {
        guard event.phase == .began, NSEvent.isSwipeTrackingFromScrollEventsEnabled,
            abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) * 2, !scrollsSideways(under: event)
        else { return }
        let history = browser.history
        event.trackSwipeEvent(
            options: [.lockDirection, .clampGestureAmount], dampenAmountThresholdMin: history.canGoForward ? -1 : 0,
            max: history.canGoBack ? 1 : 0
        ) { amount, phase, _, _ in
            guard phase == .ended else { return }
            MainActor.assumeIsolated {
                if amount > 0 { browser.history.back() } else if amount < 0 { browser.history.forward() }
            }
        }
    }

    private func scrollsSideways(under event: NSEvent) -> Bool {
        guard let content = event.window?.contentView else { return false }
        var view = content.hitTest(content.convert(event.locationInWindow, from: nil))
        while let current = view {
            if let scroll = current as? NSScrollView, let document = scroll.documentView,
                document.frame.width > scroll.contentView.bounds.width + 1
            {
                return true
            }
            view = current.superview
        }
        return false
    }
}
