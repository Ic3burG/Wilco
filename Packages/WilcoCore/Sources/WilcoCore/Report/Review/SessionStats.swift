import Foundation

/// Numbers behind a session review, worked out from the saved lines alone.
public struct SessionStats: Sendable {
    public var lines: Int
    /// Seconds from the session start to the last line.
    public var duration: Double
    /// 90th percentile of line delay across the session; nil with no lines.
    public var delayP90: Double?
    public var fillerShare: Double
    /// Share of the lines that report a confidence and have less than 0.5.
    public var unclearShare: Double
    public var channels: [UUID: ChannelStats]
    /// Session start, seconds since 1970, worked out from the lines.
    public var start: Double

    /// Short acknowledgements that carry little on their own.
    public static let fillerWords: Set<String> = [
        "yeah", "yep", "yes", "uh", "um", "mm", "mm-hmm", "hmm", "okay", "ok", "oh", "hey",
        "copy", "that", "whoa", "right", "good", "so", "and", "no",
    ]
    /// A line written this long after it started took the full utterance
    /// limit (20 s plus about a second to transcribe).
    public static let cappedDelay: Double = 19

    public static func make(_ segments: [TranscriptSegment]) -> SessionStats {
        let start = segments.map { $0.timestamp.timeIntervalSince1970 - $0.sessionOffset }.min() ?? 0
        var channels: [UUID: ChannelStats] = [:]
        var confidences: [UUID: [Double]] = [:]
        var allDelays: [Double] = []
        var fillers = 0, unclear = 0
        for segment in segments.sorted(by: { $0.sessionOffset < $1.sessionOffset }) {
            var channel = channels[segment.channelID] ?? ChannelStats()
            let delay = delay(of: segment, sessionStart: start)
            channel.lines += 1
            channel.delays.append(delay)
            allDelays.append(delay)
            if delay >= cappedDelay { channel.capped += 1 }
            if isFiller(segment) { channel.fillers += 1; fillers += 1 }
            if let confidence = segment.confidence {
                confidences[segment.channelID, default: []].append(confidence)
                if confidence < ShowReport.unclearBelow { unclear += 1 }
            }
            channels[segment.channelID] = channel
        }
        for (id, values) in confidences { channels[id]?.medianConfidence = median(values) }
        for (id, channel) in channels { channels[id]?.delayP90 = percentile(channel.delays, 0.9) }
        let count = segments.count
        return SessionStats(
            lines: count,
            duration: segments.map(\.sessionOffset).max() ?? 0,
            delayP90: percentile(allDelays, 0.9),
            fillerShare: count == 0 ? 0 : Double(fillers) / Double(count),
            unclearShare: count == 0 ? 0 : Double(unclear) / Double(count),
            channels: channels,
            start: start
        )
    }

    /// How long after the line started it was written. Timestamps are whole
    /// seconds, so this is good to about a second.
    public static func delay(of segment: TranscriptSegment, sessionStart: Double) -> Double {
        segment.timestamp.timeIntervalSince1970 - sessionStart - segment.sessionOffset
    }

    /// Lowercased words: runs of letters, apostrophes and hyphens.
    static func words(_ text: String) -> [Substring] {
        text.lowercased().split { !($0.isLetter || $0 == "'" || $0 == "-") }
    }

    /// Two words or fewer that are all fillers, or one word heard unclearly.
    static func isFiller(_ segment: TranscriptSegment) -> Bool {
        let words = words(segment.text)
        guard !words.isEmpty, words.count <= 2 else { return false }
        if words.allSatisfy({ fillerWords.contains(String($0)) }) { return true }
        return words.count == 1 && (segment.confidence ?? 1) < ShowReport.unclearBelow
    }

    static func percentile(_ values: [Double], _ p: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int(p * Double(sorted.count)))]
    }

    static func median(_ values: [Double]) -> Double? { percentile(values, 0.5) }
}

/// One channel's share of a session review.
public struct ChannelStats: Sendable {
    public var lines = 0
    public var fillers = 0
    /// Lines that took the full utterance limit.
    public var capped = 0
    public var medianConfidence: Double?
    /// Delay of each line, in session order.
    public var delays: [Double] = []
    public var delayP90: Double?
}
