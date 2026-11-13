import Foundation

/// What a transcriber reports: words in progress (volatile) or a settled line.
public struct TranscriptionEvent: Equatable, Sendable {
    public var channelID: UUID
    public var text: String
    public var isFinal: Bool
    /// Seconds since the capture session started.
    public var sessionOffset: Double
    public var confidence: Double?

    public init(channelID: UUID, text: String, isFinal: Bool, sessionOffset: Double, confidence: Double?) {
        self.channelID = channelID
        self.text = text
        self.isFinal = isFinal
        self.sessionOffset = sessionOffset
        self.confidence = confidence
    }
}

/// The on-screen transcript: settled lines in order, plus each channel's
/// words in progress. Bounded so a long show cannot grow it without limit;
/// the session file keeps everything.
public struct TranscriptTimeline: Sendable {
    public private(set) var segments: [TranscriptSegment] = []
    public private(set) var volatile: [UUID: String] = [:]
    public let maximumSegments: Int

    public init(maximumSegments: Int = 5_000) {
        self.maximumSegments = maximumSegments
    }

    /// Applies an event; returns the new segment when a line settles.
    /// `annotate` adds what automation found (keywords, highlights) before
    /// the line is stored.
    @discardableResult
    public mutating func apply(
        _ event: TranscriptionEvent,
        at date: Date,
        annotate: (inout TranscriptSegment) -> Void = { _ in }
    ) -> TranscriptSegment? {
        let text = event.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard event.isFinal else {
            volatile[event.channelID] = text.isEmpty ? nil : text
            return nil
        }
        volatile[event.channelID] = nil
        guard !text.isEmpty else { return nil }
        var segment = TranscriptSegment(
            channelID: event.channelID,
            text: text,
            timestamp: date,
            sessionOffset: event.sessionOffset,
            isFinal: true,
            confidence: event.confidence
        )
        annotate(&segment)
        segments.append(segment)
        if segments.count > maximumSegments {
            segments.removeFirst(segments.count - maximumSegments)
        }
        return segment
    }

    public func segments(for channelID: UUID) -> [TranscriptSegment] {
        segments.filter { $0.channelID == channelID }
    }

    public mutating func clear(channelID: UUID? = nil) {
        if let channelID {
            segments.removeAll { $0.channelID == channelID }
            volatile[channelID] = nil
        } else {
            segments = []
            volatile = [:]
        }
    }
}
