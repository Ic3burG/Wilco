import AppKit
import SwiftUI
import WilcoCore

/// This Mac's display preferences: transcript text and order, motion, and
/// matrix columns, stored in user defaults.
@MainActor
@Observable
final class LookAndFeel {
    var appearance: TranscriptAppearance {
        didSet { saveAppearance() }
    }

    var matrix: MatrixLayout {
        didSet { saveMatrix() }
    }

    /// One matrix column per channel, or per group.
    var matrixMode: MatrixMode {
        didSet { defaults.set(matrixMode.rawValue, forKey: Key.matrixMode) }
    }

    /// Sidebar folders the user has closed. Per Mac, not in the show file.
    var collapsedGroups: Set<UUID> {
        didSet { defaults.set(collapsedGroups.map(\.uuidString).sorted(), forKey: Key.collapsedGroups) }
    }

    /// Light, dark, or whatever the system uses. Applied app-wide, so the
    /// Settings and Report windows, menus and alerts all follow it.
    var theme: AppTheme {
        didSet {
            defaults.set(theme.rawValue, forKey: Key.theme)
            applyTheme()
        }
    }

    /// macOS Reduce Motion; when on, nothing animates whatever the style.
    private(set) var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    /// The animation for list and view changes, or nil for none.
    var animation: Animation? {
        guard !reduceMotion else { return nil }
        switch appearance.motion {
        case .smooth: return .smooth(duration: 0.3)
        case .snappy: return .snappy(duration: 0.25, extraBounce: 0.08)
        case .bouncy: return .bouncy(duration: 0.4, extraBounce: 0.22)
        case .still: return nil
        }
    }

    private let defaults: UserDefaults
    private var observer: NSObjectProtocol?

    private enum Key {
        static let fontSize = "transcript.fontSize"
        static let followLive = "transcript.followLive"
        static let showTimecode = "transcript.showTimecode"
        static let newestFirst = "transcript.newestFirst"
        static let motion = "transcript.motion"
        static let widths = "matrix.columnWidths"
        static let fontSizes = "matrix.fontSizes"
        static let collapsed = "matrix.collapsedChannels"
        static let collapsedGroups = "sidebar.collapsedGroups"
        static let matrixMode = "matrix.mode"
        static let theme = "appearance.theme"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        let stored = TranscriptAppearance()
        appearance = TranscriptAppearance(
            fontSize: defaults.object(forKey: Key.fontSize) as? Double ?? stored.fontSize,
            followLive: defaults.object(forKey: Key.followLive) as? Bool ?? stored.followLive,
            showTimecode: defaults.object(forKey: Key.showTimecode) as? Bool ?? stored.showTimecode,
            newestFirst: defaults.object(forKey: Key.newestFirst) as? Bool ?? stored.newestFirst,
            motion: defaults.string(forKey: Key.motion).flatMap(MotionStyle.init(rawValue:)) ?? stored.motion
        )
        matrix = MatrixLayout(propertyLists: (
            widths: defaults.dictionary(forKey: Key.widths) as? [String: Double] ?? [:],
            fontSizes: defaults.dictionary(forKey: Key.fontSizes) as? [String: Double] ?? [:],
            collapsed: defaults.stringArray(forKey: Key.collapsed) ?? []
        ))

        matrixMode = defaults.string(forKey: Key.matrixMode).flatMap(MatrixMode.init(rawValue:)) ?? .channels
        collapsedGroups = Set((defaults.stringArray(forKey: Key.collapsedGroups) ?? []).compactMap(UUID.init(uuidString:)))

        theme = defaults.string(forKey: Key.theme).flatMap(AppTheme.init(rawValue:)) ?? .system
        applyTheme()

        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            }
        }
    }

    /// Sets the appearance on the application rather than on each window:
    /// a nil appearance hands control back to the system, which SwiftUI's
    /// `preferredColorScheme(nil)` does not reliably do on macOS.
    private func applyTheme() {
        let name: NSAppearance.Name? = switch theme {
        case .system: nil
        case .light: .aqua
        case .dark: .darkAqua
        }
        NSApplication.shared.appearance = name.flatMap(NSAppearance.init(named:))
    }

    func adjustFontSize(by step: Double) {
        appearance.fontSize += step
    }

    func resetFontSize() {
        appearance.fontSize = TranscriptAppearance.defaultFontSize
    }

    private func saveAppearance() {
        defaults.set(appearance.fontSize, forKey: Key.fontSize)
        defaults.set(appearance.followLive, forKey: Key.followLive)
        defaults.set(appearance.showTimecode, forKey: Key.showTimecode)
        defaults.set(appearance.newestFirst, forKey: Key.newestFirst)
        defaults.set(appearance.motion.rawValue, forKey: Key.motion)
    }

    private func saveMatrix() {
        let lists = matrix.propertyLists
        defaults.set(lists.widths, forKey: Key.widths)
        defaults.set(lists.fontSizes, forKey: Key.fontSizes)
        defaults.set(lists.collapsed, forKey: Key.collapsed)
    }
}
