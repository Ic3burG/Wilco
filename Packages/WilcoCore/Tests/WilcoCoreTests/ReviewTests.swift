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
