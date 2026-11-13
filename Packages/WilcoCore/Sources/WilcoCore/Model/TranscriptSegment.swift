import Foundation

/// One transcribed line. Final segments are appended to the session's
/// `.jsonl` file as they happen, one JSON object per line.
public struct TranscriptSegment: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var channelID: UUID
    public var text: String
    public var timestamp: Date
    /// Seconds since the capture session started.
    public var sessionOffset: Double
    public var isFinal: Bool
    public var confidence: Double?
    public var matchedKeywords: [String]
    public var highlights: [SegmentHighlight]

    public init(
        id: UUID = UUID(),
        channelID: UUID,
        text: String,
        timestamp: Date,
        sessionOffset: Double,
        isFinal: Bool,
        confidence: Double? = nil,
        matchedKeywords: [String] = [],
        highlights: [SegmentHighlight] = []
    ) {
        self.id = id
        self.channelID = channelID
        self.text = text
        self.timestamp = timestamp
        self.sessionOffset = sessionOffset
        self.isFinal = isFinal
        self.confidence = confidence
        self.matchedKeywords = matchedKeywords
        self.highlights = highlights
    }
}

public struct SegmentHighlight: Codable, Equatable, Sendable {
    public var phrase: String
    public var tint: ChannelTint

    public init(phrase: String, tint: ChannelTint) {
        self.phrase = phrase
        self.tint = tint
    }
}
