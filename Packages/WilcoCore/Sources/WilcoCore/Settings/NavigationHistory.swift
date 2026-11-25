/// Back and forward history for a window that shows one page at a time, as
/// System Settings does. The caller owns the current page; the history keeps
/// the pages behind and ahead of it.
public struct NavigationHistory<Page: Equatable & Sendable>: Sendable {
    private var back: [Page] = []
    private var forward: [Page] = []
    /// How many pages each direction remembers. Older ones are dropped.
    public let limit: Int

    public init(limit: Int = 50) {
        self.limit = max(1, limit)
    }

    public var canGoBack: Bool { !back.isEmpty }
    public var canGoForward: Bool { !forward.isEmpty }

    /// Records a move the user made (a sidebar click, a search result).
    /// A fresh visit clears the forward pages, like a browser.
    public mutating func visit(from current: Page, to next: Page) {
        guard current != next else { return }
        back.append(current)
        if back.count > limit { back.removeFirst(back.count - limit) }
        forward.removeAll()
    }

    /// The page to show for Back, or nil when there is none.
    public mutating func goBack(from current: Page) -> Page? {
        guard let page = back.popLast() else { return nil }
        forward.append(current)
        return page
    }

    /// The page to show for Forward, or nil when there is none.
    public mutating func goForward(from current: Page) -> Page? {
        guard let page = forward.popLast() else { return nil }
        back.append(current)
        return page
    }
}
