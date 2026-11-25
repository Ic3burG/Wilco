/// The pages of the Settings window, in sidebar order.
///
/// Show pages hold what is saved in the show and are listed in the order a
/// new show is usually set up. Mac pages hold preferences and downloads
/// shared by every show on this Mac.
public enum SettingsPage: String, CaseIterable, Sendable, Identifiable {
    case audio
    case speech
    case destinations
    case rules
    case markers
    case general
    case appearance
    case speechModels
    case learning

    /// Which sidebar heading a page sits under. Not called `Group`, which
    /// would shadow SwiftUI's inside the app.
    public enum Area: Sendable {
        case show
        case mac
    }

    /// `UserDefaults` key holding the selected page's raw value.
    public static let storageKey = "settings.selectedPage"

    public var id: String { rawValue }

    public var area: Area {
        switch self {
        case .audio, .speech, .destinations, .rules, .markers: .show
        case .general, .appearance, .speechModels, .learning: .mac
        }
    }

    public var title: String {
        switch self {
        case .audio: "Audio"
        case .speech: "Speech"
        case .destinations: "Destinations"
        case .rules: "Rules & Highlights"
        case .markers: "Markers"
        case .general: "General"
        case .appearance: "Appearance"
        case .speechModels: "Speech Models"
        case .learning: "Learning"
        }
    }

    /// The page a stored preference names. A missing, renamed or hand-edited
    /// value opens Audio rather than nothing.
    public static func restored(from raw: String?) -> SettingsPage {
        raw.flatMap(SettingsPage.init(rawValue:)) ?? .audio
    }
}
