import Foundation
import Speech
import WhisperKit
import WilcoCore

/// One entry in a channel's language menu.
public struct LanguageOption: Hashable, Identifiable, Sendable {
    /// What is stored in `ChannelConfig.localeIdentifier`. Empty means
    /// "detect automatically", which only Whisper can do.
    public var id: String
    public var name: String

    public static let autoDetect = LanguageOption(id: "", name: "Detect Automatically")
}

/// The languages each engine can transcribe, named for the person reading
/// the menu ("English (United States)" rather than "en_US").
public enum LanguageCatalog {
    public static func options(for engine: SpeechEngine) async -> [LanguageOption] {
        if engine != .whisper, #available(macOS 26, *) {
            let locales = engine == .dictation
                ? await DictationTranscriber.supportedLocales
                : await SpeechTranscriber.supportedLocales
            return sorted(locales.map { LanguageOption(id: $0.identifier, name: displayName(for: $0.identifier)) })
        }
        // Whisper is one multilingual model: it wants a bare language code.
        let whisper = Set(Constants.languages.values).map {
            LanguageOption(id: $0, name: displayName(for: $0))
        }
        return [.autoDetect] + sorted(whisper)
    }

    /// The menu entry a stored identifier belongs to. Whisper matches on the
    /// language alone, so a channel set to "en_US" shows as English there.
    public static func selection(for stored: String, engine: SpeechEngine, in options: [LanguageOption]) -> String {
        guard !stored.isEmpty else { return stored }
        if engine == .whisper {
            return Locale(identifier: stored).language.languageCode?.identifier ?? stored
        }
        let wanted = Locale(identifier: stored).identifier(.bcp47)
        return options.first { Locale(identifier: $0.id).identifier(.bcp47) == wanted }?.id ?? stored
    }

    public static func displayName(for identifier: String) -> String {
        if identifier.isEmpty { return LanguageOption.autoDetect.name }
        return Locale.current.localizedString(forIdentifier: identifier) ?? identifier
    }

    private static func sorted(_ options: [LanguageOption]) -> [LanguageOption] {
        options.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
