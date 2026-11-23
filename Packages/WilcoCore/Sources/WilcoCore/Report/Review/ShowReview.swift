import Foundation

/// Where a review draws its lines. Starting values, tuned on saved sessions.
public enum ReviewThresholds {
    /// Sessions shorter than this have too little to judge; only show setup is checked.
    public static let minimumLines = 50
    public static let busyMinimumLines = 300
    public static let busyShare = 0.25
    /// A highlight this busy on a busy channel gets a "keep it off" fix.
    public static let busyHighlightHits = 10
    /// Busy only means something when this many other channels talked too.
    public static let busyOtherChannels = 4
    public static let busyOtherChannelLines = 30
    public static let unclearMinimumLines = 30
    public static let unclearMedian = 0.8
    /// Engines differ in how confident they sound, so a channel is unclear
    /// only this far below the whole session's median.
    public static let unclearBelowSession = 0.08
    public static let quietMinimumHours = 2.0
    public static let quietLinesPerHour = 4.0
    public static let quietSessionLinesPerHour = 200.0
    public static let cutMinimum = 10
    public static let behindRise = 5.0
    public static let behindThirdMinimumLines = 50
    public static let commonPhrasePerHour = 10.0
    public static let commonPhraseMinimumHits = 20
    /// A 20 ms frame above this level (linear, about -46 dBFS) is sound.
    public static let soundFloor: Float = 0.005
    /// A sample at or above this magnitude is clipped.
    public static let clipLevel: Float = 0.999
    /// A minute with at least this many seconds of sound counts as a sound minute.
    public static let soundMinuteSeconds = 1.0
    /// A full minute with less audio than this lost some (a stuck or starved engine).
    public static let lostMinuteAudio = 50.0
    /// No input: the loudest sample all session was below this (dBFS).
    public static let noInputPeak = -60.0
    /// Low level: the median RMS of sound minutes was below this (dBFS).
    public static let lowLevelRMS = -40.0
    /// A channel "has sound" when this share of its minutes were sound minutes.
    public static let quietSoundShare = 0.1
    public static let musicMinimumMinutes = 30
    public static let musicShare = 0.6
    /// Hot: clipping in this share of sound minutes.
    public static let hotClipShare = 0.05
    public static let lowLevelMinimumMinutes = 30
    /// Lost: this many seconds dropped over the session.
    public static let lostDroppedSeconds = 5.0
}

/// What went wrong in one session, with fixes to offer.
public struct ShowReview: Sendable {
    public var stats: SessionStats
    public var findings: [Finding]
    /// Words to offer for the show vocabulary; the "vocabulary" finding lists them.
    public var suggestions: [VocabularySuggestion]
    /// Up to four earlier sessions of the same show, newest first.
    public var trend: [SessionSummary]

    /// Whether fixes from this review belong in `show`: it must have at
    /// least one of the channels the session heard. Fixes that name no
    /// channel (vocabulary) would otherwise land in any open show.
    public func applies(to show: ShowDocument) -> Bool {
        show.channels.contains { stats.channels[$0.id] != nil }
    }

    /// `history` is earlier sessions of the same show; their names count
    /// towards vocabulary suggestions. `showIsKnown` is false when `show` is
    /// only a stand-in (no copy beside the session and no saved show shares
    /// its channels): checks that judge the show itself are skipped.
    public static func make(segments: [TranscriptSegment], show: ShowDocument, history: [SessionSummary] = [],
                            showIsKnown: Bool = true, diagnostics: SessionDiagnostics? = nil) -> ShowReview {
        let stats = SessionStats.make(segments)
        var names = NameCounts.make(segments)
        for summary in history { names.add(summary.names) }
        let suggestions = stats.lines >= ReviewThresholds.minimumLines
            ? VocabularySuggestions.suggest(counts: names, show: show) : []
        var builder = Builder(segments: segments, show: show, stats: stats, diagnostics: diagnostics)
        if showIsKnown { builder.checkSetup() }
        var quiet: [QuietChannel] = []
        if stats.lines >= ReviewThresholds.minimumLines {
            if showIsKnown { quiet = builder.quietChannels() }
            builder.checkBusy()
            builder.checkUnclear()
            builder.checkQuiet(quiet)
            builder.checkCut()
            builder.checkBehind()
            builder.checkCommonPhrases()
            builder.checkVocabulary(suggestions)
        }
        builder.checkMusic()
        builder.checkHot()
        builder.checkLowLevel(excluding: Set(quiet.map(\.channel.id)))
        builder.checkLost()
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

/// Why a quiet channel was quiet, as far as its measurements say.
private enum QuietReason {
    case noInput, lowLevel, notSpeech

    var text: String {
        switch self {
        case .noInput: "no input"
        case .lowLevel: "low level"
        case .notSpeech: "not speech"
        }
    }
}

private struct QuietChannel {
    var channel: ChannelConfig
    var count: Int
    var reason: QuietReason?
}

private struct Builder {
    let segments: [TranscriptSegment]
    let show: ShowDocument
    let stats: SessionStats
    var diagnostics: SessionDiagnostics?
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
                title: "“\(rule.name.trimmingCharacters(in: .whitespaces))” notifications have no real title",
                detail: "Its alerts are titled “New Rule” or nothing. Use the rule’s name, so renaming the rule renames its alerts.",
                channelID: nil, evidence: [],
                fixes: [FindingFix(fix: .useRuleNameAsTitle(rule: rule.id), label: "Use the rule’s name")]
            ), weight: 0)
        }
    }

    /// The fixes for a channel that drowns out the rest: keep each highlight
    /// that fired often on it off the channel, then mute it. Only when the
    /// channel is in the show. The text says how many lines each highlight hit.
    func keepOffAndMuteFixes(for id: UUID, lines mine: [TranscriptSegment]) -> (fixes: [FindingFix], hitText: String) {
        guard show.channel(id: id) != nil else { return ([], "") }
        var hits: [UUID: Int] = [:]
        for line in mine {
            for highlight in Set(line.highlights.flatMap { highlights(withPhrase: $0.phrase) }.map(\.id)) {
                hits[highlight, default: 0] += 1
            }
        }
        var fixes: [FindingFix] = []
        var hitText = ""
        for highlight in show.highlights where (hits[highlight.id] ?? 0) >= ReviewThresholds.busyHighlightHits {
            fixes.append(FindingFix(fix: .keepHighlight(highlight.id, offChannel: id),
                                    label: "Keep “\(highlight.name)” off \(name(id))"))
            hitText += " “\(highlight.name)” highlighted \(hits[highlight.id]!.formatted()) of them."
        }
        fixes.append(FindingFix(fix: .muteChannel(id), label: "Mute \(name(id))"))
        return (fixes, hitText)
    }

    static func dBText(_ value: Double) -> String {
        value < 0 ? "−\(Int(abs(value).rounded()))" : "\(Int(value.rounded()))"
    }

    mutating func checkBusy() {
        for (id, channel) in stats.channels {
            let share = Double(channel.lines) / Double(stats.lines)
            let othersTalking = stats.channels.filter { $0.key != id && $0.value.lines >= ReviewThresholds.busyOtherChannelLines }.count
            guard channel.lines >= ReviewThresholds.busyMinimumLines, share >= ReviewThresholds.busyShare,
                  othersTalking >= ReviewThresholds.busyOtherChannels else { continue }
            let mine = lines(on: id)
            let (fixes, hitText) = keepOffAndMuteFixes(for: id, lines: mine)
            add(Finding(
                id: "busy:\(id)", severity: .info,
                title: "\(name(id)) carried \(percent(share)) of the session",
                detail: "\(channel.lines.formatted()) lines, more than a quarter of everything heard.\(hitText)",
                channelID: id, evidence: Self.mostRepeated(mine), fixes: fixes
            ), weight: channel.lines)
        }
    }

    mutating func checkUnclear() {
        guard let session = SessionStats.median(segments.compactMap(\.confidence)) else { return }
        for (id, channel) in stats.channels {
            guard channel.lines >= ReviewThresholds.unclearMinimumLines,
                  let median = channel.medianConfidence, median < ReviewThresholds.unclearMedian,
                  median <= session - ReviewThresholds.unclearBelowSession else { continue }
            let lowest = lines(on: id).filter { $0.confidence != nil }
                .sorted { $0.confidence! < $1.confidence! }.prefix(3).map(\.id)
            var levelText = ""
            if let rms = diagnostics?.channels[id]?.medianRMS, rms < ReviewThresholds.lowLevelRMS {
                levelText = " Its level was low (median \(Self.dBText(rms)) dBFS), which may be why."
            }
            add(Finding(
                id: "unclear:\(id)", severity: .warning,
                title: "\(name(id)) is hard to make out",
                detail: "Median confidence \(String(format: "%.2f", median)) over \(channel.lines.formatted()) lines, against \(String(format: "%.2f", session)) for the session. Names and callsigns suffer most; check the input level and the vocabulary suggestions.\(levelText)",
                channelID: id, evidence: Array(lowest), fixes: []
            ), weight: channel.lines)
        }
    }

    /// Channels that barely spoke, with a reason where the measurements give
    /// one. Empty when the session was too short or too calm to judge.
    func quietChannels() -> [QuietChannel] {
        guard hours >= ReviewThresholds.quietMinimumHours,
              Double(stats.lines) / hours >= ReviewThresholds.quietSessionLinesPerHour else { return [] }
        return show.channels
            .filter { !$0.isMuted }
            .map { (channel: $0, count: stats.channels[$0.id]?.lines ?? 0) }
            .filter { Double($0.count) / hours < ReviewThresholds.quietLinesPerHour }
            .sorted { ($0.count, $0.channel.name) > ($1.count, $1.channel.name) }
            .map { QuietChannel(channel: $0.channel, count: $0.count, reason: quietReason(for: $0.channel.id)) }
    }

    func quietReason(for id: UUID) -> QuietReason? {
        guard let d = diagnostics?.channels[id] else { return nil }
        guard let peak = d.peak, peak >= ReviewThresholds.noInputPeak else { return .noInput }
        let hasSound = Double(d.soundMinutes) >= ReviewThresholds.quietSoundShare * Double(d.minutes)
        guard hasSound else { return nil }
        if let rms = d.medianRMS, rms < ReviewThresholds.lowLevelRMS { return .lowLevel }
        if d.classifiedSoundMinutes > 0, d.speechMinutes * 2 < d.classifiedSoundMinutes { return .notSpeech }
        return nil
    }

    mutating func checkQuiet(_ quiet: [QuietChannel]) {
        guard !quiet.isEmpty else { return }
        let list = quiet.map { entry in
            let count = entry.count == 0 ? "none" : "\(entry.count)"
            return "\(entry.channel.name) (\(count)\(entry.reason.map { ", \($0.text)" } ?? ""))"
        }.joined(separator: ", ")
        var advice: [String] = []
        if quiet.contains(where: { $0.reason == .noInput }) {
            advice.append("Nothing reached the input of the channels marked no input; check the patch.")
        }
        if quiet.contains(where: { $0.reason == .lowLevel }) {
            advice.append("Raise the input level of the channels marked low level.")
        }
        if quiet.contains(where: { $0.reason == .notSpeech }) {
            advice.append("The channels marked not speech carried mostly music or noise.")
        }
        let ending = advice.isEmpty
            ? "If they should have been talking, check the patch and input level." : advice.joined(separator: " ")
        add(Finding(
            id: "quiet", severity: .info,
            title: quiet.count == 1 ? "\(quiet[0].channel.name) barely spoke" : "\(quiet.count) channels barely spoke",
            detail: "Lines in \(Self.hoursText(hours)) while the session was busy: \(list). \(ending)",
            channelID: quiet.count == 1 ? quiet[0].channel.id : nil,
            evidence: quiet.flatMap { lines(on: $0.channel.id) }.prefix(3).map(\.id), fixes: []
        ), weight: quiet.count)
    }

    mutating func checkCut() {
        let exact = diagnostics?.channels.values.compactMap(\.cuts)
        let capped = exact?.isEmpty == false ? exact!.reduce(0, +) : stats.channels.values.reduce(0) { $0 + $1.capped }
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

    mutating func checkMusic() {
        guard let diagnostics else { return }
        for (id, d) in diagnostics.channels {
            guard d.classifiedSoundMinutes >= ReviewThresholds.musicMinimumMinutes,
                  Double(d.musicMinutes) / Double(d.classifiedSoundMinutes) >= ReviewThresholds.musicShare else { continue }
            let mine = lines(on: id)
            let (fixes, hitText) = keepOffAndMuteFixes(for: id, lines: mine)
            add(Finding(
                id: "music:\(id)", severity: .info,
                title: "\(name(id)) is mostly music",
                detail: "Music or singing in \(d.musicMinutes.formatted()) of \(d.classifiedSoundMinutes.formatted()) minutes with sound. Speech models turn music into words that aren’t there.\(hitText)",
                channelID: id, evidence: Self.mostRepeated(mine), fixes: fixes
            ), weight: d.musicMinutes)
        }
    }

    mutating func checkHot() {
        guard let diagnostics else { return }
        for (id, d) in diagnostics.channels {
            guard d.soundMinutes > 0, d.clippedSoundMinuteShare >= ReviewThresholds.hotClipShare else { continue }
            add(Finding(
                id: "hot:\(id)", severity: .warning,
                title: "\(name(id)) is too loud",
                detail: "The signal clipped in \(percent(d.clippedSoundMinuteShare)) of the minutes with sound. Clipping distorts speech and hurts recognition; lower the input gain.",
                channelID: id, evidence: [], fixes: []
            ), weight: Int((d.clippedSoundMinuteShare * Double(d.soundMinutes)).rounded()))
        }
    }

    mutating func checkLowLevel(excluding listed: Set<UUID>) {
        guard let diagnostics else { return }
        for (id, d) in diagnostics.channels where !listed.contains(id) {
            guard d.soundMinutes >= ReviewThresholds.lowLevelMinimumMinutes,
                  let rms = d.medianRMS, rms < ReviewThresholds.lowLevelRMS else { continue }
            add(Finding(
                id: "low:\(id)", severity: .warning,
                title: "\(name(id)) is too quiet",
                detail: "Its level was low (median \(Self.dBText(rms)) dBFS over \(d.soundMinutes.formatted()) minutes with sound). Raise the input gain so speech reaches the model clearly.",
                channelID: id, evidence: [], fixes: []
            ), weight: d.soundMinutes)
        }
    }

    mutating func checkLost() {
        guard let diagnostics else { return }
        let fellBehind = found.contains { $0.finding.id == "behind" }
        let clock = DateFormatter()
        clock.dateFormat = "HH:mm"
        for (id, d) in diagnostics.channels {
            let dropped = d.droppedSeconds >= ReviewThresholds.lostDroppedSeconds
            guard dropped || !d.lostMinutes.isEmpty else { continue }
            var parts: [String] = []
            if !d.lostMinutes.isEmpty {
                let times = d.lostMinutes.sorted().prefix(5)
                    .map { clock.string(from: Date(timeIntervalSince1970: stats.start + Double($0) * 60)) }
                let more = d.lostMinutes.count > 5 ? " and \(d.lostMinutes.count - 5) more" : ""
                parts.append("Audio went missing in \(d.lostMinutes.count == 1 ? "1 minute" : "\(d.lostMinutes.count) minutes"), at \(times.joined(separator: ", "))\(more).")
            }
            if dropped { parts.append("\(Int(d.droppedSeconds.rounded())) seconds were dropped because transcription couldn’t keep up.") }
            if fellBehind { parts.append("Transcription fell behind, which may be why audio was lost.") }
            add(Finding(
                id: "lost:\(id)", severity: .warning,
                title: "\(name(id)) lost audio",
                detail: parts.joined(separator: " "),
                channelID: id, evidence: [], fixes: []
            ), weight: max(d.lostMinutes.count, 1))
        }
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
