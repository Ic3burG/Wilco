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
    /// The speaker's letter within this channel ("A", "B", ...). `nil` when
    /// voice changes are off or the voice is unknown. Optionals are encoded
    /// only when present, so lines without a voice are written as before.
    public var voice: String?
    /// Per-channel exchange counter, so "A in exchange 3" differs from "A in
    /// exchange 4".
    public var exchange: Int?

    public init(
        id: UUID = UUID(),
        channelID: UUID,
        text: String,
        timestamp: Date,
        sessionOffset: Double,
        isFinal: Bool,
        confidence: Double? = nil,
        matchedKeywords: [String] = [],
        highlights: [SegmentHighlight] = [],
        voice: String? = nil,
        exchange: Int? = nil
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
        self.voice = voice
        self.exchange = exchange
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
