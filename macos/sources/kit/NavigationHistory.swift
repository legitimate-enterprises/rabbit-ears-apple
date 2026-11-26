/// The detail stack and the pages gone back over, for Forward. Every change
/// goes through `path`, the stack's own pops included: one that drops pages
/// off the top keeps them for Forward, and any other change forgets them.
public struct NavigationHistory<Page: Hashable> {
    private var pages: [Page] = []
    /// Nearest last.
    private var ahead: [Page] = []
    /// Each page's name as its screen gave it, for the back button.
    public var titles: [Page: String] = [:]

    public init() {}

    public var path: [Page] {
        get { pages }
        set {
            if newValue.count < pages.count, Array(pages.prefix(newValue.count)) == newValue {
                ahead += pages[newValue.count...].reversed()
            } else if newValue != pages {
                ahead = []
            }
            pages = newValue
        }
    }

    public var canGoBack: Bool { !pages.isEmpty }
    public var canGoForward: Bool { !ahead.isEmpty }

    public mutating func back() {
        if canGoBack { path.removeLast() }
    }

    public mutating func forward() {
        guard let next = ahead.popLast() else { return }
        pages.append(next)
    }

    public mutating func reset() {
        pages = []
        ahead = []
    }

    /// The back button's title: `root` under the first page, nil at the root.
    public func backTitle(root: String) -> String? {
        guard canGoBack else { return nil }
        guard pages.count > 1 else { return root }
        return titles[pages[pages.count - 2]] ?? "Back"
    }
}
