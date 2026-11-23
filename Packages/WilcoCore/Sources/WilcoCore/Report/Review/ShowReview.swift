import Foundation

/// Where a review draws its lines. Starting values, tuned on saved sessions.
public enum ReviewThresholds {
    /// Sessions shorter than this have too little to judge; only show setup is checked.
    public static let minimumLines = 50
    public static let busyMinimumLines = 300
    public static let busyShare = 0.25
    /// A highlight this busy on a busy channel gets a "keep it off" fix.
    public static let busyHighlightHits = 10
    public static let unclearMinimumLines = 30
    public static let unclearMedian = 0.8
    public static let quietMinimumHours = 2.0
    public static let quietLinesPerHour = 4.0
    public static let quietSessionLinesPerHour = 200.0
    public static let cutMinimum = 10
    public static let behindRise = 5.0
    public static let behindThirdMinimumLines = 50
    public static let commonPhrasePerHour = 10.0
    public static let commonPhraseMinimumHits = 20
}

/// What went wrong in one session, with fixes to offer.
public struct ShowReview: Sendable {
    public var stats: SessionStats
    public var findings: [Finding]
    /// Words to offer for the show vocabulary; the "vocabulary" finding lists them.
    public var suggestions: [VocabularySuggestion]
    /// Up to four earlier sessions of the same show, newest first.
    public var trend: [SessionSummary]

    /// `history` is earlier sessions of the same show; their names count
    /// towards vocabulary suggestions.
    public static func make(segments: [TranscriptSegment], show: ShowDocument, history: [SessionSummary] = []) -> ShowReview {
        let stats = SessionStats.make(segments)
        var names = NameCounts.make(segments)
        for summary in history { names.add(summary.names) }
        let suggestions = stats.lines >= ReviewThresholds.minimumLines
            ? VocabularySuggestions.suggest(counts: names, show: show) : []
        var builder = Builder(segments: segments, show: show, stats: stats)
        builder.checkSetup()
        if stats.lines >= ReviewThresholds.minimumLines {
            builder.checkBusy()
            builder.checkUnclear()
            builder.checkQuiet()
            builder.checkCut()
            builder.checkBehind()
            builder.checkCommonPhrases()
            builder.checkVocabulary(suggestions)
        }
        let findings = builder.found
            .sorted { ($0.finding.severity, -$0.weight) < ($1.finding.severity, -$1.weight) }
            .map(\.finding)
        return ShowReview(stats: stats, findings: findings, suggestions: suggestions, trend: Array(history.prefix(4)))
    }
}

public struct Finding: Identifiable, Sendable {
    public enum Severity: Int, Comparable, Sendable {
        case problem, warning, info
        public static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }
    }

    /// Stable across runs (check plus channel, rule or highlight), so a
    /// dismissed finding stays dismissed.
    public var id: String
    public var severity: Severity
    public var title: String
    public var detail: String
    public var channelID: UUID?
    /// Up to three lines that show the problem.
    public var evidence: [UUID]
    public var fixes: [FindingFix]
}

public struct FindingFix: Hashable, Sendable {
    public var fix: ShowFix
    public var label: String
}

private struct Builder {
    let segments: [TranscriptSegment]
    let show: ShowDocument
    let stats: SessionStats
    var found: [(finding: Finding, weight: Int)] = []

    var hours: Double { stats.duration / 3600 }

    func name(_ channel: UUID) -> String { show.channel(id: channel)?.name ?? "Unknown channel" }
    func lines(on channel: UUID) -> [TranscriptSegment] { segments.filter { $0.channelID == channel } }
    func percent(_ share: Double) -> String { "\(Int((share * 100).rounded()))%" }

    mutating func add(_ finding: Finding, weight: Int) { found.append((finding, weight)) }

    /// Enabled highlights in the show that contain a phrase.
    func highlights(withPhrase phrase: String) -> [HighlightRule] {
        let lowered = phrase.lowercased()
        return show.highlights.filter { $0.isEnabled && $0.phrases.contains { $0.lowercased() == lowered } }
    }

    mutating func checkSetup() {
        for rule in show.rules {
            let leftover = rule.actions.contains { action in
                if case .notify(let title, _) = action { return ShowFix.isLeftoverTitle(title) }
                return false
            }
            guard leftover else { continue }
            add(Finding(
                id: "setup:\(rule.id)", severity: .problem,
                title: "“\(rule.name)” notifications have no real title",
                detail: "Its alerts are titled “New Rule” or nothing. Use the rule’s name, so renaming the rule renames its alerts.",
                channelID: nil, evidence: [],
                fixes: [FindingFix(fix: .useRuleNameAsTitle(rule: rule.id), label: "Use the rule’s name")]
            ), weight: 0)
        }
    }

    mutating func checkBusy() {
        for (id, channel) in stats.channels {
            let share = Double(channel.lines) / Double(stats.lines)
            guard channel.lines >= ReviewThresholds.busyMinimumLines, share >= ReviewThresholds.busyShare else { continue }
            let mine = lines(on: id)
            var hits: [UUID: Int] = [:]
            for line in mine {
                for highlight in Set(line.highlights.flatMap { highlights(withPhrase: $0.phrase) }.map(\.id)) {
                    hits[highlight, default: 0] += 1
                }
            }
            var fixes: [FindingFix] = []
            var hitText = ""
            if show.channel(id: id) != nil {
                for highlight in show.highlights where (hits[highlight.id] ?? 0) >= ReviewThresholds.busyHighlightHits {
                    fixes.append(FindingFix(fix: .keepHighlight(highlight.id, offChannel: id),
                                            label: "Keep “\(highlight.name)” off \(name(id))"))
                    hitText += " “\(highlight.name)” highlighted \(hits[highlight.id]!.formatted()) of them."
                }
                fixes.append(FindingFix(fix: .muteChannel(id), label: "Mute \(name(id))"))
            }
            add(Finding(
                id: "busy:\(id)", severity: .warning,
                title: "\(name(id)) carried \(percent(share)) of the session",
                detail: "\(channel.lines.formatted()) lines, more than a quarter of everything heard.\(hitText)",
                channelID: id, evidence: Self.mostRepeated(mine), fixes: fixes
            ), weight: channel.lines)
        }
    }

    mutating func checkUnclear() {
        for (id, channel) in stats.channels {
            guard channel.lines >= ReviewThresholds.unclearMinimumLines,
                  let median = channel.medianConfidence, median < ReviewThresholds.unclearMedian else { continue }
            let lowest = lines(on: id).filter { $0.confidence != nil }
                .sorted { $0.confidence! < $1.confidence! }.prefix(3).map(\.id)
            add(Finding(
                id: "unclear:\(id)", severity: .warning,
                title: "\(name(id)) is hard to make out",
                detail: "Median confidence \(String(format: "%.2f", median)) over \(channel.lines.formatted()) lines. Names and callsigns suffer most; check the input level and the vocabulary suggestions.",
                channelID: id, evidence: Array(lowest), fixes: []
            ), weight: channel.lines)
        }
    }

    mutating func checkQuiet() {
        guard hours >= ReviewThresholds.quietMinimumHours,
              Double(stats.lines) / hours >= ReviewThresholds.quietSessionLinesPerHour else { return }
        for channel in show.channels where !channel.isMuted {
            let count = stats.channels[channel.id]?.lines ?? 0
            guard Double(count) / hours < ReviewThresholds.quietLinesPerHour else { continue }
            add(Finding(
                id: "quiet:\(channel.id)", severity: .info,
                title: "\(channel.name) barely spoke",
                detail: count == 0
                    ? "No lines in \(Self.hoursText(hours)) while the session was busy. Check its patch and input level."
                    : "\(count) lines in \(Self.hoursText(hours)) while the session was busy. Check its patch and input level.",
                channelID: channel.id, evidence: lines(on: channel.id).prefix(3).map(\.id), fixes: []
            ), weight: -count)
        }
    }

    mutating func checkCut() {
        let capped = stats.channels.values.reduce(0) { $0 + $1.capped }
        guard capped >= ReviewThresholds.cutMinimum else { return }
        let examples = segments
            .filter { SessionStats.delay(of: $0, sessionStart: stats.start) >= SessionStats.cappedDelay }
            .prefix(3).map(\.id)
        add(Finding(
            id: "cut", severity: .info,
            title: "\(capped) lines ran the full 20 seconds",
            detail: "Someone talked without a pause long enough that the line was cut at the limit and carried on in the next.",
            channelID: nil, evidence: Array(examples), fixes: []
        ), weight: capped)
    }

    mutating func checkBehind() {
        guard stats.duration > 0 else { return }
        let third = stats.duration / 3
        let delays = segments.map { ($0.sessionOffset, SessionStats.delay(of: $0, sessionStart: stats.start)) }
        let first = delays.filter { $0.0 < third }.map(\.1)
        let last = delays.filter { $0.0 >= 2 * third }.map(\.1)
        guard first.count >= ReviewThresholds.behindThirdMinimumLines, last.count >= ReviewThresholds.behindThirdMinimumLines,
              let early = SessionStats.percentile(first, 0.9), let late = SessionStats.percentile(last, 0.9),
              late - early >= ReviewThresholds.behindRise else { return }
        add(Finding(
            id: "behind", severity: .info,
            title: "Transcription fell behind",
            detail: String(format: "The slowest lines took %.0f s to appear at the start and %.0f s by the end. Try fewer channels or a lighter latency profile.", early, late),
            channelID: nil, evidence: [], fixes: []
        ), weight: Int(late - early))
    }

    mutating func checkCommonPhrases() {
        guard hours > 0 else { return }
        var highlightHits: [String: [TranscriptSegment]] = [:]
        var ruleHits: [String: [TranscriptSegment]] = [:]
        for line in segments {
            for phrase in Set(line.highlights.map { $0.phrase.lowercased() }) { highlightHits[phrase, default: []].append(line) }
            for phrase in Set(line.matchedKeywords.map { $0.lowercased() }) { ruleHits[phrase, default: []].append(line) }
        }
        func common(_ hits: [TranscriptSegment]) -> Bool {
            hits.count >= ReviewThresholds.commonPhraseMinimumHits
                && Double(hits.count) / hours >= ReviewThresholds.commonPhrasePerHour
        }
        for (phrase, hits) in highlightHits where common(hits) {
            let perHour = Int((Double(hits.count) / hours).rounded())
            for highlight in highlights(withPhrase: phrase) {
                let channels = Set(hits.map(\.channelID)).count
                add(Finding(
                    id: "phrase:\(highlight.id):\(phrase)", severity: .warning,
                    title: "“\(phrase)” highlights \(perHour) times an hour",
                    detail: "The “\(highlight.name)” highlight matched \(hits.count.formatted()) lines on \(channels) channel\(channels == 1 ? "" : "s"). A word this common stops standing out.",
                    channelID: nil, evidence: hits.prefix(3).map(\.id),
                    fixes: [FindingFix(fix: .removePhrase(phrase, fromHighlight: highlight.id),
                                       label: "Remove “\(phrase)” from \(highlight.name)")]
                ), weight: hits.count)
            }
        }
        for (phrase, hits) in ruleHits where common(hits) {
            let perHour = Int((Double(hits.count) / hours).rounded())
            for rule in show.rules where rule.isEnabled && rule.phrases.contains(where: { $0.lowercased() == phrase }) {
                add(Finding(
                    id: "phrase:\(rule.id):\(phrase)", severity: .warning,
                    title: "“\(phrase)” fires “\(rule.name)” \(perHour) times an hour",
                    detail: "Matched \(hits.count.formatted()) lines. Edit the rule’s phrases in Settings › Automation if that’s more than you want.",
                    channelID: nil, evidence: hits.prefix(3).map(\.id), fixes: []
                ), weight: hits.count)
            }
        }
    }

    mutating func checkVocabulary(_ suggestions: [VocabularySuggestion]) {
        guard !suggestions.isEmpty else { return }
        let misheard = suggestions.filter { $0.heardAs != nil }
        let detail = misheard.isEmpty
            ? "Names heard often that the vocabulary doesn’t know yet. Adding them helps the speech model spell them."
            : misheard.map { "“\($0.term)” was heard as “\($0.heardAs!)” \($0.count) times." }.joined(separator: " ")
                + " Adding names to the vocabulary helps the speech model hear them."
        add(Finding(
            id: "vocabulary", severity: .info, title: "Words to add to the vocabulary", detail: detail,
            channelID: nil, evidence: [],
            fixes: misheard.isEmpty ? [] : [FindingFix(fix: .addVocabulary(misheard.map(\.term)),
                                                       label: "Add \(misheard.count) to vocabulary")]
        ), weight: suggestions.count)
    }

    /// One line each for the channel's most repeated texts.
    static func mostRepeated(_ lines: [TranscriptSegment]) -> [UUID] {
        var first: [String: UUID] = [:]
        var counts: [String: Int] = [:]
        for line in lines {
            let key = line.text.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
            counts[key, default: 0] += 1
            if first[key] == nil { first[key] = line.id }
        }
        return counts.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.prefix(3).compactMap { first[$0.key] }
    }

    static func hoursText(_ hours: Double) -> String {
        hours < 1 ? "\(Int((hours * 60).rounded())) minutes" : String(format: "%.1f hours", hours)
    }
}
