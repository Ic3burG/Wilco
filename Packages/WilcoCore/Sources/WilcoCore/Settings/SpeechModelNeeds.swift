import Foundation

/// Which speech downloads are still needed, for Settings › Speech Models.
public enum SpeechModelNeeds {
    /// Long-form languages macOS holds for Wilco that neither a long-form
    /// channel nor anything in `alsoNeeded` (such as the language learning
    /// labels clips with) uses, so they can be offered for removal.
    /// Identifiers are compared as BCP 47, so `en_US` and `en-US` match.
    public static func unusedLongFormLocales(
        reserved: [String],
        channels: [ChannelConfig],
        alsoNeeded: [String]
    ) -> [String] {
        let used = Set(channels.filter { $0.engine == .longForm }.map(\.localeIdentifier).map(bcp47))
            .union(alsoNeeded.map(bcp47))
        return reserved.filter { !used.contains(bcp47($0)) }
    }

    private static func bcp47(_ identifier: String) -> String {
        Locale(identifier: identifier).identifier(.bcp47)
    }
}
