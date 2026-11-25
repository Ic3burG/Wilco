import Foundation

/// How transcripts read on this Mac. A personal preference, not part of the show.
public struct TranscriptAppearance: Equatable, Sendable {
    public static let fontSizeRange: ClosedRange<Double> = 10...28
    public static let defaultFontSize: Double = 13

    public var fontSize: Double {
        didSet { fontSize = min(max(fontSize, Self.fontSizeRange.lowerBound), Self.fontSizeRange.upperBound) }
    }
    /// Keep the newest line in view as lines arrive.
    public var followLive: Bool
    public var showTimecode: Bool
    /// The newest line at the top, reading downward into the past.
    public var newestFirst: Bool

    public init(
        fontSize: Double = TranscriptAppearance.defaultFontSize,
        followLive: Bool = true,
        showTimecode: Bool = true,
        newestFirst: Bool = false
    ) {
        self.fontSize = min(max(fontSize, Self.fontSizeRange.lowerBound), Self.fontSizeRange.upperBound)
        self.followLive = followLive
        self.showTimecode = showTimecode
        self.newestFirst = newestFirst
    }

    /// Lines in reading order, given lines oldest first.
    public func ordered<Lines: BidirectionalCollection>(_ lines: Lines) -> [Lines.Element] {
        newestFirst ? Array(lines.reversed()) : Array(lines)
    }
}

/// Light or dark, chosen in Wilco rather than taken from System Settings.
/// Useful in a dark booth on a Mac that is otherwise kept in light mode.
public enum AppTheme: String, CaseIterable, Sendable {
    case system, light, dark

    public var title: String {
        switch self {
        case .system: "Match System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    public var symbol: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max"
        case .dark: "moon"
        }
    }
}
