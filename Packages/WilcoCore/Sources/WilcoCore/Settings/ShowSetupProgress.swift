/// Whether a show page in Settings looks set up, for the tick beside it.
///
/// A tick is a hint, worked out from the show each time, never stored, and
/// never stops anyone opening or using a page.
public enum ShowSetupProgress {
    /// - Parameters:
    ///   - connectedDeviceUIDs: UIDs of the audio devices connected now.
    ///   - isInstalled: whether the model for an engine and locale identifier
    ///     is on this Mac. An empty identifier means the Mac's own language,
    ///     as on a channel.
    public static func isSetUp(
        _ page: SettingsPage,
        show: ShowDocument,
        connectedDeviceUIDs: Set<String>,
        isInstalled: (SpeechEngine, String) -> Bool
    ) -> Bool {
        switch page {
        case .audio:
            guard !show.channels.isEmpty else { return false }
            // nil is System Default, which is always there.
            return show.deviceUID.map(connectedDeviceUIDs.contains) ?? true
        case .speech:
            guard !show.channels.isEmpty else { return false }
            var seen = Set<String>()
            for channel in show.channels
            where seen.insert("\(channel.engine.rawValue)|\(channel.localeIdentifier)").inserted {
                if !isInstalled(channel.engine, channel.localeIdentifier) { return false }
            }
            return true
        case .destinations:
            return show.destinations.contains(where: \.isEnabled)
        case .rules:
            return show.rules.contains(where: \.isEnabled) || show.highlights.contains(where: \.isEnabled)
        case .markers, .general, .appearance, .speechModels, .learning:
            return false
        }
    }
}
