import Foundation

/// Per-channel column settings for the matrix view: width, text size and
/// whether the column is collapsed. Kept by channel ID, so reordering or
/// adding channels never shifts one column's settings onto another.
public struct MatrixLayout: Equatable, Sendable {
    public static let defaultWidth: Double = 280
    public static let widthRange: ClosedRange<Double> = 160...640
    public static let collapsedWidth: Double = 36

    private var widths: [UUID: Double] = [:]
    private var fontSizes: [UUID: Double] = [:]
    private var collapsed: Set<UUID> = []

    public init() {}

    // MARK: Widths

    public func width(for id: UUID) -> Double {
        widths[id] ?? Self.defaultWidth
    }

    /// What the column occupies on screen.
    public func displayWidth(for id: UUID) -> Double {
        isCollapsed(id) ? Self.collapsedWidth : width(for: id)
    }

    public mutating func setWidth(_ width: Double, for id: UUID) {
        widths[id] = Self.clampedWidth(width)
    }

    /// Shares `available` width equally among the open columns.
    public mutating func fit(_ ids: [UUID], into available: Double) {
        let open = ids.filter { !isCollapsed($0) }
        guard !open.isEmpty else { return }
        let collapsedSpace = Double(ids.count - open.count) * Self.collapsedWidth
        let each = (available - collapsedSpace) / Double(open.count)
        for id in open { setWidth(each, for: id) }
    }

    public mutating func resetWidths() {
        widths = [:]
    }

    private static func clampedWidth(_ width: Double) -> Double {
        min(max(width, widthRange.lowerBound), widthRange.upperBound)
    }

    // MARK: Collapsing

    public func isCollapsed(_ id: UUID) -> Bool {
        collapsed.contains(id)
    }

    public mutating func setCollapsed(_ isCollapsed: Bool, for id: UUID) {
        if isCollapsed { collapsed.insert(id) } else { collapsed.remove(id) }
    }

    public mutating func expandAll() {
        collapsed = []
    }

    // MARK: Text size

    /// The column's own text size, or `defaultSize` (the transcript size).
    public func fontSize(for id: UUID, default defaultSize: Double) -> Double {
        fontSizes[id] ?? defaultSize
    }

    public mutating func setFontSize(_ size: Double, for id: UUID) {
        fontSizes[id] = Self.clampedFontSize(size)
    }

    public mutating func resetFontSizes() {
        fontSizes = [:]
    }

    private static func clampedFontSize(_ size: Double) -> Double {
        let range = TranscriptAppearance.fontSizeRange
        return min(max(size, range.lowerBound), range.upperBound)
    }

    // MARK: Storage

    /// Values for user defaults, keyed by channel UUID string.
    public var propertyLists: (widths: [String: Double], fontSizes: [String: Double], collapsed: [String]) {
        (
            Dictionary(uniqueKeysWithValues: widths.map { ($0.key.uuidString, $0.value) }),
            Dictionary(uniqueKeysWithValues: fontSizes.map { ($0.key.uuidString, $0.value) }),
            collapsed.map(\.uuidString).sorted()
        )
    }

    /// Restores stored values, skipping any that are damaged and clamping the rest.
    public init(propertyLists: (widths: [String: Double], fontSizes: [String: Double], collapsed: [String])) {
        for (key, value) in propertyLists.widths {
            if let id = UUID(uuidString: key) { widths[id] = Self.clampedWidth(value) }
        }
        for (key, value) in propertyLists.fontSizes {
            if let id = UUID(uuidString: key) { fontSizes[id] = Self.clampedFontSize(value) }
        }
        collapsed = Set(propertyLists.collapsed.compactMap(UUID.init(uuidString:)))
    }
}
