import Foundation

extension ShowDocument {
    /// Terms biased into a channel's recogniser: show vocabulary, the
    /// channel's own terms, then phrases of enabled rules and highlights that
    /// listen to this channel. Phrases come back spelled the way rules expect.
    public func vocabulary(for channelID: ChannelConfig.ID) -> [String] {
        let applies = { (channelIDs: Set<UUID>) in channelIDs.isEmpty || channelIDs.contains(channelID) }
        var terms = globalVocabulary
        terms += channel(id: channelID)?.vocabulary ?? []
        terms += rules.filter { $0.isEnabled && applies($0.channelIDs) }.flatMap(\.phrases)
        terms += highlights.filter { $0.isEnabled && applies($0.channelIDs) }.flatMap(\.phrases)

        var seen = Set<String>()
        return terms
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }
}
