import Foundation

/// Decides which rules a settled line fires, honouring each rule's cooldown.
public struct AutomationEvaluator: Sendable {
    public struct Firing: Equatable, Sendable {
        public var rule: AutomationRule
        /// The phrases that were heard.
        public var matched: [String]
    }

    private var lastFired: [AutomationRule.ID: Date] = [:]

    public init() {}

    /// Rules fired by `segment`, in rule order. A rule within its cooldown
    /// is skipped: comms repeat, and one spoken standby should fire one cue.
    public mutating func evaluate(_ segment: TranscriptSegment, in show: ShowDocument, at now: Date) -> [Firing] {
        evaluate(text: segment.text, channelID: segment.channelID, in: show, at: now)
    }

    /// Rules fired by a line's text on a channel. Used for a recognised line,
    /// which fires rules before it becomes a segment.
    public mutating func evaluate(text: String, channelID: UUID, in show: ShowDocument, at now: Date) -> [Firing] {
        var firings: [Firing] = []
        for rule in show.rules where rule.isEnabled && Self.listens(rule.channelIDs, to: channelID) {
            let matched = KeywordMatcher.matches(rule.phrases, in: text, mode: rule.matchMode)
            guard !matched.isEmpty else { continue }
            if let last = lastFired[rule.id], now.timeIntervalSince(last) < rule.cooldown { continue }
            lastFired[rule.id] = now
            firings.append(Firing(rule: rule, matched: matched))
        }
        return firings
    }

    public mutating func reset() {
        lastFired = [:]
    }

    /// Every phrase the firings heard, once each (ignoring case), in order.
    public static func matchedKeywords(_ firings: [Firing]) -> [String] {
        var seen = Set<String>()
        return firings.flatMap(\.matched).filter { seen.insert($0.lowercased()).inserted }
    }

    /// The matched phrases that occur in `text`, matched as whole words and
    /// ignoring case, as rules match. Used to give each voice-annotated
    /// piece of a line the keywords it said.
    public static func keywords(_ matched: [String], in text: String) -> [String] {
        KeywordMatcher.matches(matched, in: text, mode: .containsAny)
    }

    /// Phrases to tint in a line, from enabled highlight rules for its channel.
    public static func highlights(for text: String, channelID: UUID, in show: ShowDocument) -> [SegmentHighlight] {
        show.highlights
            .filter { $0.isEnabled && listens($0.channelIDs, to: channelID) }
            .flatMap { rule in
                KeywordMatcher.matches(rule.phrases, in: text, mode: rule.matchMode)
                    .map { SegmentHighlight(phrase: $0, tint: rule.tint) }
            }
    }

    static func listens(_ channelIDs: Set<UUID>, to channelID: UUID) -> Bool {
        channelIDs.isEmpty || channelIDs.contains(channelID)
    }
}

/// One line of the Activity log.
public struct ActivityEntry: Identifiable, Equatable, Sendable {
    public enum Kind: String, Sendable { case fired, error, info }

    public var id = UUID()
    public var date: Date
    public var kind: Kind
    public var ruleName: String
    public var detail: String

    public init(date: Date = .now, kind: Kind, ruleName: String, detail: String) {
        self.date = date
        self.kind = kind
        self.ruleName = ruleName
        self.detail = detail
    }
}
