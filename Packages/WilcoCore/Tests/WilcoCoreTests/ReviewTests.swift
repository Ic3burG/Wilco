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
