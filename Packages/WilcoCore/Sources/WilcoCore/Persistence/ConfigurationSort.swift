import Foundation

extension ConfigurationSummary {
    /// The order the configurations list starts in: by name, Finder style.
    public static let nameOrder = KeyPathComparator(\ConfigurationSummary.name, comparator: .localizedStandard)

    /// Sorts by the clicked column(s), then by name so rows that tie (same
    /// channel count or save time) keep a stable, predictable order.
    public static func sorted(
        _ configurations: [ConfigurationSummary],
        using order: [KeyPathComparator<ConfigurationSummary>]
    ) -> [ConfigurationSummary] {
        configurations.sorted(using: order + [nameOrder])
    }
}
