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
    let audio = HighlightRule(name: "Audio Related", phrases: ["hear"])

    var show: ShowDocument { ShowDocument(channels: [band, sm, quiet], highlights: [audio]) }

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
            + many(250, on: sm.id, over: 7200)
        let review = ShowReview.make(segments: lines, show: show)
        let busy = try #require(review.findings.first { $0.id == "busy:\(band.id)" })
        #expect(busy.channelID == band.id)
        #expect(busy.fixes.map(\.fix) == [.keepHighlight(audio.id, offChannel: band.id), .muteChannel(band.id)])
        #expect(!review.findings.contains { $0.id == "busy:\(sm.id)" })
    }

    @Test func quietChannelNeedsABusySession() {
        let busy = many(900, on: sm.id, over: 3 * 3600) + many(3, on: quiet.id, over: 3 * 3600)
        let ids = ShowReview.make(segments: busy, show: show).findings.map(\.id)
        #expect(ids.contains("quiet:\(quiet.id)"))
        // A channel in the show that never spoke is quiet too.
        #expect(ids.contains("quiet:\(band.id)"))

        let calm = many(100, on: sm.id, over: 3 * 3600) + many(3, on: quiet.id, over: 3 * 3600)
        #expect(!ShowReview.make(segments: calm, show: show).findings.contains { $0.id.hasPrefix("quiet:") })
    }

    @Test func unclearChannelIsAWarning() throws {
        let lines = many(40, on: sm.id, over: 3600, confidence: 0.6) + many(40, on: band.id, over: 3600)
        let finding = try #require(ShowReview.make(segments: lines, show: show).findings.first { $0.id == "unclear:\(sm.id)" })
        #expect(finding.severity == .warning)
        #expect(finding.evidence.count == 3)
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
