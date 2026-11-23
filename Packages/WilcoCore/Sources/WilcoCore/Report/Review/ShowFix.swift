import Foundation

/// A change a review can offer to make to a show, in one click.
///
/// Shows have no identity of their own, so a fix names the channels,
/// highlights and rules it touches; it can be applied to any show that has
/// all of them (in practice the show the session was recorded with).
public enum ShowFix: Hashable, Sendable {
    case muteChannel(UUID)
    /// Stop a highlight colouring one channel's lines.
    case keepHighlight(UUID, offChannel: UUID)
    case removePhrase(String, fromHighlight: UUID)
    case addVocabulary([String])
    /// Title the rule's notifications `{rule}`, so they follow its name.
    case useRuleNameAsTitle(rule: UUID)

    /// Notification titles that were never set on purpose.
    static func isLeftoverTitle(_ title: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed == "New Rule"
    }
}

extension ShowDocument {
    /// Whether every channel, highlight or rule the fix names is in this show.
    public func canApply(_ fix: ShowFix) -> Bool {
        let channelIDs = Set(channels.map(\.id))
        switch fix {
        case .muteChannel(let id):
            return channelIDs.contains(id)
        case .keepHighlight(let highlight, let channel):
            return highlights.contains { $0.id == highlight } && channelIDs.contains(channel)
        case .removePhrase(_, let highlight):
            return highlights.contains { $0.id == highlight }
        case .addVocabulary:
            return true
        case .useRuleNameAsTitle(let rule):
            return rules.contains { $0.id == rule }
        }
    }

    /// Whether the show already looks the way the fix would leave it.
    public func isApplied(_ fix: ShowFix) -> Bool {
        guard canApply(fix) else { return false }
        return applying(fix) == self
    }

    /// The show with the fix made; unchanged when it can't be applied.
    public func applying(_ fix: ShowFix) -> ShowDocument {
        guard canApply(fix) else { return self }
        var show = self
        switch fix {
        case .muteChannel(let id):
            if let index = show.channels.firstIndex(where: { $0.id == id }) { show.channels[index].isMuted = true }
        case .keepHighlight(let highlight, let channel):
            // A highlight that is off already colours nothing.
            if let index = show.highlights.firstIndex(where: { $0.id == highlight && $0.isEnabled }) {
                // An empty list means every channel, so spell out the others.
                var listed = show.highlights[index].channelIDs
                if listed.isEmpty { listed = Set(show.channels.map(\.id)) }
                listed.remove(channel)
                if listed.isEmpty {
                    // That was its only channel: emptying the list would widen it.
                    show.highlights[index].isEnabled = false
                } else {
                    show.highlights[index].channelIDs = listed
                }
            }
        case .removePhrase(let phrase, let highlight):
            if let index = show.highlights.firstIndex(where: { $0.id == highlight }) {
                let lowered = phrase.lowercased()
                show.highlights[index].phrases.removeAll { $0.lowercased() == lowered }
            }
        case .addVocabulary(let terms):
            for term in terms {
                let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty,
                      !show.globalVocabulary.contains(where: { $0.lowercased() == trimmed.lowercased() })
                else { continue }
                show.globalVocabulary.append(trimmed)
            }
        case .useRuleNameAsTitle(let rule):
            if let index = show.rules.firstIndex(where: { $0.id == rule }) {
                show.rules[index].actions = show.rules[index].actions.map { action in
                    guard case .notify(let title, let body) = action, ShowFix.isLeftoverTitle(title) else { return action }
                    return .notify(title: "{rule}", bodyTemplate: body)
                }
            }
        }
        return show
    }
}
