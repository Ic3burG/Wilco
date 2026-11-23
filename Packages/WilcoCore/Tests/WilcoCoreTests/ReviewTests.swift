import Foundation
import Testing
@testable import WilcoCore

/// A line said at `offset` seconds into a session that started at `start`,
/// written `delay` seconds later.
func reviewLine(
    _ text: String, channel: UUID, at offset: Double, delay: Double = 1, confidence: Double? = 0.9,
    start: Date = Date(timeIntervalSince1970: 1_800_000_000), keywords: [String] = [],
    highlights: [SegmentHighlight] = []
) -> TranscriptSegment {
    TranscriptSegment(
        channelID: channel, text: text, timestamp: start.addingTimeInterval(offset + delay),
        sessionOffset: offset, isFinal: true, confidence: confidence,
        matchedKeywords: keywords, highlights: highlights
    )
}

@Suite("Session stats")
struct SessionStatsTests {
    let a = UUID()

    @Test func delayIsTimestampMinusStartAndOffset() throws {
        let stats = SessionStats.make([
            reviewLine("Standby lasers.", channel: a, at: 10, delay: 1),
            reviewLine("Lasers go.", channel: a, at: 20, delay: 4),
        ])
        let channel = try #require(stats.channels[a])
        // The fastest line defines the session start, so its delay is 0.
        #expect(channel.delays == [0, 3])
        #expect(stats.lines == 2)
    }

    @Test func fillersCountOneWordAndUnclearSingles() throws {
        let stats = SessionStats.make([
            reviewLine("Yeah.", channel: a, at: 1),
            reviewLine("Copy that.", channel: a, at: 2),
            reviewLine("Go.", channel: a, at: 3, confidence: 0.3),
            reviewLine("Standby lasers.", channel: a, at: 4),
        ])
        #expect(try #require(stats.channels[a]).fillers == 3)
        #expect(stats.fillerShare == 0.75)
    }

    @Test func nilConfidenceIsNotUnclear() throws {
        let stats = SessionStats.make([
            reviewLine("Hold please.", channel: a, at: 1, confidence: nil),
            reviewLine("Go.", channel: a, at: 2, confidence: nil),
        ])
        #expect(stats.unclearShare == 0)
        #expect(try #require(stats.channels[a]).medianConfidence == nil)
        #expect(try #require(stats.channels[a]).fillers == 0)
    }

    @Test func emptySessionHasZeroShares() {
        let stats = SessionStats.make([])
        #expect(stats.lines == 0)
        #expect(stats.fillerShare == 0)
        #expect(stats.unclearShare == 0)
        #expect(stats.delayP90 == nil)
    }

    @Test func linesThatTookTheFullLimitCountAsCapped() throws {
        let stats = SessionStats.make([
            reviewLine("Short.", channel: a, at: 0, delay: 1),
            reviewLine("A very long talk", channel: a, at: 30, delay: 20.5),
        ])
        #expect(try #require(stats.channels[a]).capped == 1)
    }
}

@Suite("Show fixes")
struct ShowFixTests {
    let band = ChannelConfig(name: "Band TB")
    let sm = ChannelConfig(name: "ShowCall PL")
    let highlight = HighlightRule(name: "Audio Related", phrases: ["hear", "loud"])

    var show: ShowDocument { ShowDocument(channels: [band, sm], highlights: [highlight]) }

    @Test func muteAppliesOnceAndReportsDone() {
        let fix = ShowFix.muteChannel(band.id)
        #expect(show.canApply(fix))
        #expect(!show.isApplied(fix))
        let fixed = show.applying(fix)
        #expect(fixed.channel(id: band.id)?.isMuted == true)
        #expect(fixed.channel(id: sm.id)?.isMuted == false)
        #expect(fixed.isApplied(fix))
    }

    @Test func removePhraseIgnoresCase() {
        let fix = ShowFix.removePhrase("Hear", fromHighlight: highlight.id)
        let fixed = show.applying(fix)
        #expect(fixed.highlights[0].phrases == ["loud"])
        #expect(fixed.isApplied(fix))
    }

    @Test func keepHighlightOffChannelFromAllChannels() {
        let fixed = show.applying(.keepHighlight(highlight.id, offChannel: band.id))
        #expect(fixed.highlights[0].channelIDs == [sm.id])
    }

    @Test func keepHighlightOffChannelFromAList() {
        var listed = show
        let third = ChannelConfig(name: "Lasers")
        listed.channels.append(third)
        listed.highlights[0].channelIDs = [band.id, third.id]
        let fixed = listed.applying(.keepHighlight(highlight.id, offChannel: band.id))
        #expect(fixed.highlights[0].channelIDs == [third.id])
    }

    /// An empty list means every channel, so taking away a highlight's
    /// only channel turns it off instead of widening it.
    @Test func keepHighlightOffItsOnlyChannelTurnsItOff() {
        var only = show
        only.highlights[0].channelIDs = [band.id]
        let fix = ShowFix.keepHighlight(highlight.id, offChannel: band.id)
        let fixed = only.applying(fix)
        #expect(fixed.highlights[0].isEnabled == false)
        #expect(fixed.highlights[0].channelIDs == [band.id])
        #expect(fixed.isApplied(fix))
    }

    @Test func addVocabularySkipsKnownTermsIgnoringCase() {
        var known = show
        known.globalVocabulary = ["Omar"]
        let fix = ShowFix.addVocabulary(["omar", "Tea Time"])
        #expect(!known.isApplied(fix))
        let fixed = known.applying(fix)
        #expect(fixed.globalVocabulary == ["Omar", "Tea Time"])
        #expect(fixed.isApplied(fix))
    }

    @Test func useRuleNameAsTitleReplacesNewRule() {
        var withRule = show
        let rule = AutomationRule(name: "Omar Notifications", actions: [
            .notify(title: "New Rule", bodyTemplate: "Heard on {channel}: {text}"),
            .markCuePoint(label: "{keyword}"),
        ])
        withRule.rules = [rule]
        let fix = ShowFix.useRuleNameAsTitle(rule: rule.id)
        #expect(!withRule.isApplied(fix))
        let fixed = withRule.applying(fix)
        #expect(fixed.rules[0].actions == [
            .notify(title: "{rule}", bodyTemplate: "Heard on {channel}: {text}"),
            .markCuePoint(label: "{keyword}"),
        ])
        #expect(fixed.isApplied(fix))
    }

    @Test func fixForMissingChannelCannotApplyAndChangesNothing() {
        let fix = ShowFix.muteChannel(UUID())
        #expect(!show.canApply(fix))
        #expect(show.applying(fix) == show)
        #expect(!show.canApply(.keepHighlight(UUID(), offChannel: band.id)))
        #expect(!show.canApply(.keepHighlight(highlight.id, offChannel: UUID())))
    }

    @Test func applyingTwiceIsUnchanged() {
        for fix in [ShowFix.muteChannel(band.id), .keepHighlight(highlight.id, offChannel: band.id),
                    .removePhrase("hear", fromHighlight: highlight.id), .addVocabulary(["NPC"])] {
            let once = show.applying(fix)
            #expect(once.applying(fix) == once, "\(fix)")
        }
    }
}

@Suite("Show review")
struct ShowReviewTests {
    let band = ChannelConfig(name: "Band TB")
    let sm = ChannelConfig(name: "ShowCall PL")
    let quiet = ChannelConfig(name: "BOD")
    let others = (1...4).map { ChannelConfig(name: "Crew \($0)") }
    let audio = HighlightRule(name: "Audio Related", phrases: ["hear"])

    var show: ShowDocument { ShowDocument(channels: [band, sm, quiet] + others, highlights: [audio]) }

    /// Some talk on four more channels, so the session isn't one channel alone.
    var crew: [TranscriptSegment] { others.flatMap { many(40, on: $0.id, over: 7200) } }

    /// `count` lines on a channel, spread evenly over `seconds`.
    func many(_ count: Int, on channel: UUID, over seconds: Double, text: String = "Standby for the next cue.",
              confidence: Double = 0.9, delay: Double = 1, from: Double = 0,
              highlights: [SegmentHighlight] = []) -> [TranscriptSegment] {
        (0..<count).map { i in
            reviewLine(text, channel: channel, at: from + seconds * Double(i) / Double(max(count, 1)),
                       delay: delay, confidence: confidence, highlights: highlights)
        }
    }

    @Test func busyChannelIsFoundWithMuteFix() throws {
        let hear = [SegmentHighlight(phrase: "hear", tint: .yellow)]
        let lines = many(400, on: band.id, over: 7200, text: "Can you hear me?", highlights: hear)
            + many(250, on: sm.id, over: 7200) + crew
        let review = ShowReview.make(segments: lines, show: show)
        let busy = try #require(review.findings.first { $0.id == "busy:\(band.id)" })
        #expect(busy.channelID == band.id)
        #expect(busy.fixes.map(\.fix) == [.keepHighlight(audio.id, offChannel: band.id), .muteChannel(band.id)])
        #expect(!review.findings.contains { $0.id == "busy:\(sm.id)" })
    }

    /// Before doors one channel may be the only one talking; that's not news.
    @Test func busyNeedsOtherChannelsTalking() {
        let lines = many(400, on: band.id, over: 7200) + many(250, on: sm.id, over: 7200)
        #expect(!ShowReview.make(segments: lines, show: show).findings.contains { $0.id.hasPrefix("busy:") })
    }

    @Test func quietChannelNeedsABusySession() {
        let busy = many(900, on: sm.id, over: 3 * 3600) + many(3, on: quiet.id, over: 3 * 3600)
        let findings = ShowReview.make(segments: busy, show: show).findings
        // One finding for every quiet channel, including ones that never spoke.
        let quietOnes = findings.filter { $0.id == "quiet" }
        #expect(quietOnes.count == 1)
        #expect(quietOnes.first?.detail.contains("BOD") == true)
        #expect(quietOnes.first?.detail.contains("Band TB") == true)

        let calm = many(100, on: sm.id, over: 3 * 3600) + many(3, on: quiet.id, over: 3 * 3600)
        #expect(!ShowReview.make(segments: calm, show: show).findings.contains { $0.id == "quiet" })
    }

    @Test func unclearChannelIsAWarning() throws {
        let lines = many(40, on: sm.id, over: 3600, confidence: 0.6) + many(40, on: band.id, over: 3600)
        let finding = try #require(ShowReview.make(segments: lines, show: show).findings.first { $0.id == "unclear:\(sm.id)" })
        #expect(finding.severity == .warning)
        #expect(finding.evidence.count == 3)
    }

    /// Some engines report lower confidence across the board; a channel is
    /// unclear only next to the rest of the session.
    @Test func unclearIsRelativeToTheSession() {
        let lines = many(40, on: sm.id, over: 3600, confidence: 0.72) + many(40, on: band.id, over: 3600, confidence: 0.74)
        #expect(!ShowReview.make(segments: lines, show: show).findings.contains { $0.id.hasPrefix("unclear:") })
    }

    @Test func cutLongTalkIsCounted() {
        let lines = many(12, on: sm.id, over: 3600, delay: 20.5) + many(50, on: sm.id, over: 3600, delay: 1, from: 1)
        #expect(ShowReview.make(segments: lines, show: show).findings.contains { $0.id == "cut" })
    }

    @Test func fallingBehindIsFound() {
        let lines = many(60, on: sm.id, over: 1000, delay: 1) + many(60, on: sm.id, over: 1000, delay: 1, from: 1000)
            + many(60, on: sm.id, over: 1000, delay: 9, from: 2000)
        #expect(ShowReview.make(segments: lines, show: show).findings.contains { $0.id == "behind" })
    }

    @Test func leftoverNotificationTitleIsAProblem() throws {
        var withRule = show
        let rule = AutomationRule(name: "Omar Notifications", actions: [.notify(title: "New Rule", bodyTemplate: "{text}")])
        withRule.rules = [rule]
        let finding = try #require(ShowReview.make(segments: many(5, on: sm.id, over: 60), show: withRule)
            .findings.first { $0.id == "setup:\(rule.id)" })
        #expect(finding.severity == .problem)
        #expect(finding.fixes.map(\.fix) == [.useRuleNameAsTitle(rule: rule.id)])
    }

    @Test func commonHighlightPhraseOffersRemoval() throws {
        let hear = [SegmentHighlight(phrase: "hear", tint: .yellow)]
        let lines = many(30, on: sm.id, over: 3600, text: "I can hear you.", highlights: hear) + many(30, on: band.id, over: 3600)
        let finding = try #require(ShowReview.make(segments: lines, show: show).findings.first { $0.id.hasPrefix("phrase:") })
        #expect(finding.fixes.map(\.fix) == [.removePhrase("hear", fromHighlight: audio.id)])
        #expect(finding.title.contains("hear"))
    }

    @Test func tinySessionHasOnlySetupFindings() {
        var withRule = show
        withRule.rules = [AutomationRule(name: "Holds", actions: [.notify(title: "", bodyTemplate: "{text}")])]
        let lines = many(15, on: sm.id, over: 120, confidence: 0.3, delay: 20)
        let findings = ShowReview.make(segments: lines, show: withRule).findings
        #expect(findings.map(\.severity) == [.problem])
    }

    @Test func findingIDsAreStable() {
        let lines = many(400, on: band.id, over: 7200) + many(300, on: sm.id, over: 7200)
        #expect(ShowReview.make(segments: lines, show: show).findings.map(\.id)
            == ShowReview.make(segments: lines, show: show).findings.map(\.id))
    }

    @Test func emptySessionHasNoFindings() {
        #expect(ShowReview.make(segments: [], show: show).findings.isEmpty)
    }
}

@Suite("Vocabulary suggestions")
struct VocabularySuggestionTests {
    let tea = ChannelConfig(name: "Tea Time")
    var show: ShowDocument { ShowDocument(channels: [tea], globalVocabulary: ["Omar"]) }

    func said(_ texts: [String]) -> NameCounts {
        NameCounts.make(texts.enumerated().map { reviewLine($1, channel: tea.id, at: Double($0)) })
    }

    @Test func channelNameHeardWrongIsSuggested() throws {
        let counts = said(Array(repeating: "Omar on T Time.", count: 3) + ["Hey, Dana. Dana here, Dana."])
        let first = try #require(VocabularySuggestions.suggest(counts: counts, show: show).first)
        #expect(first == VocabularySuggestion(term: "Tea Time", heardAs: "T Time", count: 3))
    }

    /// Short names and two-letter slips match ordinary words too often
    /// ("BOD" / "God", "Triad" / "Brian").
    @Test func nearMissesNeedALongNameAndACloseMatch() {
        let strict = ShowDocument(channels: [ChannelConfig(name: "BOD"), ChannelConfig(name: "Triad")])
        let counts = said(Array(repeating: "Oh my God, ask Brian.", count: 5))
        #expect(!VocabularySuggestions.suggest(counts: counts, show: strict).contains { $0.heardAs != nil })
    }

    @Test func sentenceStartIsNotAName() {
        let counts = said(Array(repeating: "Lights. Stand by.", count: 5))
        #expect(counts.counts["Lights"] == nil)
        #expect(counts.counts["Stand"] == nil)
    }

    @Test func knownTermsAreNotSuggested() {
        let counts = said(Array(repeating: "Is that Omar on comms?", count: 4))
        #expect(!VocabularySuggestions.suggest(counts: counts, show: show).contains { $0.term == "Omar" })
    }

    @Test func exclamationsAreNotNames() {
        let counts = said(Array(repeating: "Oh my God, Jesus Christ.", count: 5))
        #expect(VocabularySuggestions.suggest(counts: counts, show: show).isEmpty)
    }

    @Test func acronymsAndRepeatedNamesCount() throws {
        let counts = said(["NPC is open.", "The NPC is open.", "Open the NPC now.", "Go to NPC.",
                           "Ask Dana.", "Copy Dana.", "Where is Dana?"])
        let terms = VocabularySuggestions.suggest(counts: counts, show: show).map(\.term)
        #expect(terms.contains("NPC"))
        #expect(terms.contains("Dana"))
    }

    @Test func pronounsAndFillersAreNotNames() {
        let counts = said(Array(repeating: "Yes I think so, Okay, I'm here.", count: 5))
        #expect(VocabularySuggestions.suggest(counts: counts, show: show).isEmpty)
    }

    @Test func findingOffersNearMissesAsTheFix() throws {
        let lines = (0..<60).map { reviewLine("Omar on T Time.", channel: tea.id, at: Double($0)) }
        let finding = try #require(ShowReview.make(segments: lines, show: show).findings.first { $0.id == "vocabulary" })
        #expect(finding.fixes.map(\.fix) == [.addVocabulary(["Tea Time"])])
        #expect(finding.fixes.first?.label == "Add 1 to vocabulary")
    }
}

@Suite("Session history")
struct SessionHistoryTests {
    let sm = ChannelConfig(name: "ShowCall PL")

    func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "review-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Writes a session with `texts` and, when `show` is given, its show copy.
    @discardableResult
    func session(_ name: String, in folder: URL, texts: [String], show: ShowDocument?) throws -> URL {
        let url = folder.appending(path: "Session \(name).jsonl")
        var data = Data()
        for (i, text) in texts.enumerated() {
            data.append(try TranscriptFile.line(for: reviewLine(text, channel: sm.id, at: Double(i) * 10)))
        }
        try data.write(to: url)
        if let show { try SessionShow.save(show, forTranscript: url) }
        return url
    }

    @Test func summaryUsesTheSessionCopyName() throws {
        let dir = try folder()
        let url = try session("2026-11-20 1900-00", in: dir, texts: ["Standby.", "Yeah."],
                              show: ShowDocument(name: "YE Dallas", channels: [sm]))
        let summary = try SessionHistory.summary(transcript: url, candidates: [ShowDocument(name: "Other", channels: [sm])])
        #expect(summary.showName == "YE Dallas")
        #expect(summary.lines == 2)
        #expect(summary.fillerShare == 0.5)
        let expected = DateComponents(calendar: .current, year: 2026, month: 11, day: 20, hour: 19).date
        #expect(summary.started == expected)
    }

    @Test func sessionWithoutCopyUsesTheBestMatch() throws {
        let dir = try folder()
        let url = try session("2026-11-20 1900-00", in: dir, texts: ["Standby."], show: nil)
        let summary = try SessionHistory.summary(transcript: url, candidates: [ShowDocument(name: "YE Phoenix", channels: [sm])])
        #expect(summary.showName == "YE Phoenix")
    }

    @Test func sameShowFiltersByNameNewestFirst() throws {
        let dir = try folder()
        let phoenix = ShowDocument(name: "YE Phoenix", channels: [sm])
        let older = try session("2026-11-19 1900-00", in: dir, texts: ["Go."], show: phoenix)
        let newer = try session("2026-11-21 1900-00", in: dir, texts: ["Go."], show: phoenix)
        let current = try session("2026-11-22 1900-00", in: dir, texts: ["Go."], show: phoenix)
        try session("2026-11-20 1900-00", in: dir, texts: ["Go."], show: ShowDocument(name: "YE Dallas", channels: [sm]))
        let all = try SessionHistory.summaries(in: dir, candidates: [])
        #expect(all.count == 4)
        let same = SessionHistory.sameShow(as: "YE Phoenix", in: all, excluding: current)
        #expect(same.map(\.id.lastPathComponent) == [newer, older].map(\.lastPathComponent))
    }

    @Test func historyNamesFeedSuggestions() throws {
        let show = ShowDocument(name: "YE Phoenix", channels: [sm])
        var before = SessionSummary(id: URL(filePath: "/a"), started: .now, showName: "YE Phoenix", lines: 2,
                                    fillerShare: 0, unclearShare: 0, delayP90: nil)
        before.names = NameCounts(counts: ["Dana": 2])
        let lines = (0..<60).map { reviewLine($0 == 0 ? "Ask Dana now." : "Standby.", channel: sm.id, at: Double($0)) }
        #expect(!ShowReview.make(segments: lines, show: show).suggestions.contains { $0.term == "Dana" })
        let review = ShowReview.make(segments: lines, show: show, history: [before])
        #expect(review.suggestions.contains { $0.term == "Dana" })
        #expect(review.trend.map(\.id) == [before.id])
    }
}

/// Reviews every saved session on this Mac and prints the findings, for
/// tuning `ReviewThresholds` by eye. Skips quietly where there are none.
@Suite("Review on real sessions", .enabled(if: FileManager.default.fileExists(atPath: DataLocations.transcripts.path)))
struct RealSessionReviewTests {
    @Test func everySessionReviewsWithoutNoise() throws {
        let store = ConfigurationStore()
        let candidates = store.list().compactMap { try? store.document($0.id) }
        let all = try SessionHistory.summaries(in: DataLocations.transcripts, candidates: candidates)
        var lastNight: ShowReview?
        var lastNightShow: ShowDocument?
        for summary in all {
            let segments = TranscriptFile.segments(in: try Data(contentsOf: summary.id))
            let show = SessionShow.load(forTranscript: summary.id)
                ?? SessionShow.bestMatch(for: segments, among: candidates) ?? ShowDocument()
            let history = SessionHistory.sameShow(as: summary.showName, in: all, excluding: summary.id)
                .filter { $0.started < summary.started }
            let review = ShowReview.make(segments: segments, show: show, history: history)
            print("== \(summary.id.lastPathComponent) [\(summary.showName)] \(summary.lines) lines, \(review.findings.count) findings")
            for finding in review.findings { print("   \(finding.severity) \(finding.title) — \(finding.detail.prefix(110))") }
            if !review.suggestions.isEmpty {
                print("   suggestions: " + review.suggestions.map { "\($0.term)\($0.heardAs.map { " (as \($0))" } ?? "") ×\($0.count)" }.joined(separator: ", "))
            }
            #expect(review.findings.count <= 8, "\(summary.id.lastPathComponent): \(review.findings.count) findings")
            if summary.id.lastPathComponent == "Session 2026-11-21 1720-52.jsonl" { lastNight = review; lastNightShow = show }
        }
        guard let lastNight, let show = lastNightShow else { return }
        func channel(_ name: String) -> UUID? { show.channels.first { $0.name == name }?.id }
        let ids = Set(lastNight.findings.map(\.id))
        #expect(channel("Band TB").map { ids.contains("busy:\($0)") } == true)
        #expect(lastNight.findings.first { $0.id == "quiet" }?.detail.contains("Automation") == true)
        #expect(lastNight.findings.contains { $0.id.hasPrefix("phrase:") && $0.title.contains("hear") })
        #expect(lastNight.suggestions.contains { $0.term == "Tea Time" })
    }

    /// Tuning aid: the diagnostics findings for each saved session that has a
    /// `.diagnostics` file. Checks no thresholds; passes with none.
    @Test func reviewsSessionsWithDiagnostics() throws {
        let store = ConfigurationStore()
        let candidates = store.list().compactMap { try? store.document($0.id) }
        let all = try SessionHistory.summaries(in: DataLocations.transcripts, candidates: candidates)
        let prefixes = ["music:", "hot:", "low:", "lost:"]
        for summary in all where FileManager.default.fileExists(atPath: DiagnosticsFile.url(forTranscript: summary.id).path) {
            let segments = TranscriptFile.segments(in: try Data(contentsOf: summary.id))
            let show = SessionShow.load(forTranscript: summary.id)
                ?? SessionShow.bestMatch(for: segments, among: candidates) ?? ShowDocument()
            let review = ShowReview.make(segments: segments, show: show, diagnostics: SessionDiagnostics.load(forTranscript: summary.id))
            let found = review.findings.filter { finding in prefixes.contains { finding.id.hasPrefix($0) } }
            print("== \(summary.id.lastPathComponent): \(found.map(\.id).joined(separator: ", "))")
            for finding in found { print("   \(finding.severity) \(finding.title) — \(finding.detail.prefix(110))") }
        }
    }
}

/// Regressions from the branch review: a session whose show is only a guess.
@Suite("Review against a guessed show")
struct GuessedShowReviewTests {
    let sm = ChannelConfig(name: "ShowCall PL")
    let other = ChannelConfig(name: "Lasers")

    @Test func guessedShowSkipsChecksThatDependOnIt() {
        let rule = AutomationRule(name: "Holds", actions: [.notify(title: "New Rule", bodyTemplate: "{text}")])
        let show = ShowDocument(channels: [sm, other], rules: [rule])
        let lines = (0..<900).map { reviewLine("Standby.", channel: sm.id, at: Double($0) * 12) }
        let known = ShowReview.make(segments: lines, show: show)
        #expect(known.findings.contains { $0.id == "quiet" })
        let guessed = ShowReview.make(segments: lines, show: show, showIsKnown: false)
        #expect(!guessed.findings.contains { $0.id == "quiet" || $0.id.hasPrefix("setup:") })
    }

    @Test func reviewAppliesOnlyToAShowSharingItsChannels() {
        let lines = [reviewLine("Standby.", channel: sm.id, at: 0)]
        let review = ShowReview.make(segments: lines, show: ShowDocument(channels: [sm]))
        #expect(review.applies(to: ShowDocument(channels: [sm, other])))
        #expect(!review.applies(to: ShowDocument(channels: [other])))
    }
}

/// Findings that come from the session's `.diagnostics` measurements.
@Suite("Review with diagnostics")
struct DiagnosticsReviewTests {
    let sm = ChannelConfig(name: "ShowCall PL")
    let band = ChannelConfig(name: "Band TB")
    let lasers = ChannelConfig(name: "Lasers")
    let highlight = HighlightRule(name: "Audio Related", phrases: ["hear"])

    func show(_ channels: ChannelConfig...) -> ShowDocument {
        ShowDocument(channels: channels.isEmpty ? [sm, band, lasers] : channels, highlights: [highlight])
    }

    /// Rows for `minutes` full minutes; `shape` adjusts each row.
    func rows(_ channel: UUID, minutes: Int = 40, sound: Double = 30, rms: Double? = -25, peak: Double? = -6,
              shape: (Int, inout ChannelMinute) -> Void = { _, _ in }) -> [ChannelMinute] {
        (0..<minutes).map { minute in
            var row = ChannelMinute(channel: channel, minute: minute, audio: 60, sound: sound, rms: rms, peak: peak)
            shape(minute, &row)
            return row
        }
    }

    func session(_ lines: Int, on channel: UUID, text: String = "Standby.", highlights: [SegmentHighlight] = []) -> [TranscriptSegment] {
        (0..<lines).map { reviewLine(text, channel: channel, at: Double($0) * 12, highlights: highlights) }
    }

    func ids(_ review: ShowReview) -> Set<String> { Set(review.findings.map(\.id)) }

    @Test func noDiagnosticsKeepsTodaysFindings() {
        let lines = session(900, on: sm.id)
        let plain = ShowReview.make(segments: lines, show: show())
        let empty = ShowReview.make(segments: lines, show: show(), diagnostics: nil)
        #expect(plain.findings.map(\.id) == empty.findings.map(\.id))
        #expect(plain.findings.contains { $0.id == "quiet" })
        let detail = plain.findings.first { $0.id == "quiet" }?.detail ?? ""
        #expect(detail.hasSuffix("If they should have been talking, check the patch and input level."))
        #expect(!detail.contains("no input"))
    }

    @Test func musicChannelOffersMuteAndHighlightFix() throws {
        let hear = [SegmentHighlight(phrase: "hear", tint: .yellow)]
        let lines = session(20, on: band.id, text: "I can hear you.", highlights: hear)
        let diagnostics = SessionDiagnostics.make(rows(band.id) { minute, row in
            row.classified = SoundShares(speech: 0.1, music: minute < 30 ? 0.8 : 0.0, singing: 0)
            if minute >= 30 { row.classified = SoundShares(speech: 0.9, music: 0, singing: 0) }
        })
        let review = ShowReview.make(segments: lines, show: show(), diagnostics: diagnostics)
        let finding = try #require(review.findings.first { $0.id == "music:\(band.id)" })
        #expect(finding.severity == .info)
        #expect(finding.fixes.map(\.fix).contains(.muteChannel(band.id)))
        #expect(finding.fixes.map(\.fix).contains(.keepHighlight(highlight.id, offChannel: band.id)))
    }

    @Test func musicWithoutChannelInShowHasNoFixes() throws {
        let stranger = UUID()
        let diagnostics = SessionDiagnostics.make(rows(stranger) { _, row in
            row.classified = SoundShares(speech: 0, music: 0.9, singing: 0)
        })
        let review = ShowReview.make(segments: session(20, on: sm.id), show: show(), diagnostics: diagnostics)
        let finding = try #require(review.findings.first { $0.id == "music:\(stranger)" })
        #expect(finding.fixes.isEmpty)
    }

    @Test func hotChannelFlagged() {
        func review(clippedMinutes: Int) -> ShowReview {
            let diagnostics = SessionDiagnostics.make(rows(sm.id) { minute, row in row.clipped = minute < clippedMinutes ? 5 : 0 })
            return ShowReview.make(segments: session(900, on: sm.id), show: show(), diagnostics: diagnostics)
        }
        #expect(ids(review(clippedMinutes: 3)).contains("hot:\(sm.id)"))
        #expect(!ids(review(clippedMinutes: 1)).contains("hot:\(sm.id)"))
    }

    @Test func lowLevelFlaggedAndUnclearMentionsIt() throws {
        let lines = (0..<400).map { reviewLine("Hold please.", channel: sm.id, at: Double($0) * 5, confidence: 0.5) }
            + (0..<400).map { reviewLine("Hold please.", channel: band.id, at: Double($0) * 5, confidence: 0.95) }
        let diagnostics = SessionDiagnostics.make(rows(sm.id, rms: -45))
        let review = ShowReview.make(segments: lines, show: show(sm, band), diagnostics: diagnostics)
        #expect(ids(review).contains("low:\(sm.id)"))
        let unclear = try #require(review.findings.first { $0.id == "unclear:\(sm.id)" })
        #expect(unclear.detail.contains("level was low"))
    }

    @Test func quietReasons() throws {
        let silent = ChannelConfig(name: "Silent")
        let faint = ChannelConfig(name: "Faint")
        let tune = ChannelConfig(name: "Tune")
        let calm = ChannelConfig(name: "Calm")
        let lines = session(900, on: sm.id)
        let diagnostics = SessionDiagnostics.make(
            rows(silent.id, sound: 0, rms: nil, peak: nil)
            + rows(faint.id, rms: -50)
            + rows(tune.id) { _, row in row.classified = SoundShares(speech: 0, music: 0.9, singing: 0) }
            + rows(calm.id, sound: 0, rms: nil, peak: -20)
        )
        let review = ShowReview.make(segments: lines, show: show(sm, silent, faint, tune, calm), diagnostics: diagnostics)
        let detail = try #require(review.findings.first { $0.id == "quiet" }).detail
        #expect(detail.contains("Silent (none, no input)"))
        #expect(detail.contains("Faint (none, low level)"))
        #expect(detail.contains("Tune (none, not speech)"))
        #expect(detail.contains("Calm (none)"))
        #expect(!detail.contains("If they should have been talking"))
        // The quiet finding explains Faint, so it doesn't also get "low".
        #expect(!ids(review).contains("low:\(faint.id)"))
    }

    @Test func lostAudioFromDropsAndGaps() throws {
        let dropped = SessionDiagnostics.make(rows(sm.id) { minute, row in if minute == 5 { row.droppedSeconds = 6 } })
        let review = ShowReview.make(segments: session(900, on: sm.id), show: show(), diagnostics: dropped)
        #expect(ids(review).contains("lost:\(sm.id)"))
        #expect(try #require(review.findings.first { $0.id == "lost:\(sm.id)" }).detail.contains("6 seconds"))

        let gap = SessionDiagnostics.make(rows(band.id) { minute, row in if minute == 7 { row.audio = 10 } })
        let lines = session(900, on: sm.id)
        let reviewed = ShowReview.make(segments: lines, show: show(), diagnostics: gap)
        let detail = try #require(reviewed.findings.first { $0.id == "lost:\(band.id)" }).detail
        let start = SessionStats.make(lines).start
        let clock = DateFormatter()
        clock.dateFormat = "HH:mm"
        #expect(detail.contains(clock.string(from: Date(timeIntervalSince1970: start + 7 * 60))))
        #expect(!detail.contains("fell behind"))
    }

    @Test func lostAudioMentionsFallingBehind() throws {
        let lines = (0..<600).map { reviewLine("Hold.", channel: sm.id, at: Double($0) * 6, delay: $0 < 300 ? 1 : 12) }
        let diagnostics = SessionDiagnostics.make(rows(sm.id) { minute, row in if minute == 7 { row.audio = 10 } })
        let review = ShowReview.make(segments: lines, show: show(), diagnostics: diagnostics)
        #expect(ids(review).contains("behind"))
        #expect(try #require(review.findings.first { $0.id == "lost:\(sm.id)" }).detail.contains("fell behind"))
    }

    @Test func cutUsesExactCount() throws {
        let diagnostics = SessionDiagnostics.make(rows(sm.id) { minute, row in row.cuts = minute < 12 ? 1 : 0 })
        let review = ShowReview.make(segments: session(900, on: sm.id), show: show(), diagnostics: diagnostics)
        #expect(try #require(review.findings.first { $0.id == "cut" }).title.contains("12"))
    }

    @Test func diagnosticsChecksRunUnderFiftyLines() {
        let diagnostics = SessionDiagnostics.make(rows(band.id) { _, row in
            row.classified = SoundShares(speech: 0, music: 0.9, singing: 0)
        })
        let review = ShowReview.make(segments: session(10, on: band.id), show: show(), diagnostics: diagnostics)
        #expect(ids(review).contains("music:\(band.id)"))
    }

    @Test func diagnosticsChecksRunForAGuessedShow() {
        let diagnostics = SessionDiagnostics.make(rows(sm.id, rms: -45))
        let review = ShowReview.make(segments: session(900, on: sm.id), show: show(), showIsKnown: false, diagnostics: diagnostics)
        #expect(ids(review).contains("low:\(sm.id)"))
    }

    @Test func musicDetailNamesItsLinesAndFewHitsOffersOnlyMute() throws {
        let hear = [SegmentHighlight(phrase: "hear", tint: .yellow)]
        let lines = session(20, on: band.id, text: "I can hear you.", highlights: hear)
        let few = Array(lines.prefix(9)) + session(11, on: band.id)
        let diagnostics = SessionDiagnostics.make(rows(band.id) { _, row in row.classified = SoundShares(speech: 0, music: 0.9, singing: 0) })
        let finding = try #require(ShowReview.make(segments: few, show: show(), diagnostics: diagnostics)
            .findings.first { $0.id == "music:\(band.id)" })
        #expect(finding.fixes.map(\.fix) == [.muteChannel(band.id)])
        let many = try #require(ShowReview.make(segments: lines, show: show(), diagnostics: diagnostics)
            .findings.first { $0.id == "music:\(band.id)" })
        #expect(many.detail.contains("of its 20 lines"))
    }

    @Test func musicShareJustUnderThresholdIsNotFlagged() {
        // 17 of 30 classified minutes is 0.567.
        let diagnostics = SessionDiagnostics.make(rows(band.id, minutes: 30) { minute, row in
            row.classified = SoundShares(speech: minute < 17 ? 0 : 0.9, music: minute < 17 ? 0.9 : 0, singing: 0)
        })
        #expect(!ids(ShowReview.make(segments: session(20, on: band.id), show: show(), diagnostics: diagnostics))
            .contains("music:\(band.id)"))
    }

    @Test func lowLevelNeedsThirtySoundMinutes() {
        let diagnostics = SessionDiagnostics.make(rows(sm.id, minutes: 29, rms: -45))
        #expect(!ids(ShowReview.make(segments: session(900, on: sm.id), show: show(), diagnostics: diagnostics))
            .contains("low:\(sm.id)"))
    }

    @Test func aMeasuredPeakBelowSixtyIsNoInput() throws {
        let diagnostics = SessionDiagnostics.make(rows(lasers.id, sound: 0, rms: nil, peak: -65) + rows(sm.id))
        let review = ShowReview.make(segments: session(900, on: sm.id), show: show(sm, lasers), diagnostics: diagnostics)
        #expect(try #require(review.findings.first { $0.id == "quiet" }).detail.contains("Lasers (none, no input)"))
    }

    @Test func lostNamesFiveMinutesAndCountsTheRest() throws {
        let diagnostics = SessionDiagnostics.make(rows(sm.id) { minute, row in if (10..<17).contains(minute) { row.audio = 10 } })
        let review = ShowReview.make(segments: session(900, on: sm.id), show: show(), diagnostics: diagnostics)
        let detail = try #require(review.findings.first { $0.id == "lost:\(sm.id)" }).detail
        #expect(detail.contains("7 minutes"))
        #expect(detail.contains("and 2 more"))
    }

    @Test func lostWithoutLinesNamesMinutesNotClockTimes() throws {
        let diagnostics = SessionDiagnostics.make(rows(sm.id) { minute, row in if minute == 7 { row.audio = 10 } })
        let review = ShowReview.make(segments: [], show: show(), diagnostics: diagnostics)
        let detail = try #require(review.findings.first { $0.id == "lost:\(sm.id)" }).detail
        #expect(detail.contains("minute 7"))
        #expect(!detail.contains("1970"))
    }

    @Test func quietChannelsWithFineInputSaySoAndUncapturedOnesAreMarked() throws {
        let calm = ChannelConfig(name: "Calm")
        let never = ChannelConfig(name: "Never")
        let lines = session(900, on: sm.id)
        let fine = SessionDiagnostics.make(rows(calm.id, sound: 0, rms: nil, peak: -20) + rows(sm.id))
        let detail = try #require(ShowReview.make(segments: lines, show: show(sm, calm), diagnostics: fine)
            .findings.first { $0.id == "quiet" }).detail
        #expect(detail.contains("measured fine"))
        #expect(!detail.contains("check the patch and input level"))
        let missing = try #require(ShowReview.make(segments: lines, show: show(sm, never), diagnostics: fine)
            .findings.first { $0.id == "quiet" }).detail
        #expect(missing.contains("Never (none, not captured)"))
    }
}
