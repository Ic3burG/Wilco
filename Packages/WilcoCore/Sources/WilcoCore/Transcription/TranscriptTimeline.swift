import Foundation

/// Where a line is in the two-stage flow: rules fire on the recognised text
/// without waiting for voice analysis, which annotates the line afterwards.
public enum LineStage: Equatable, Sendable {
    /// A finished line with nothing more to come.
    case complete
    /// The text is final; its voice is still being worked out.
    case recognized
    /// Voice analysis for an earlier `.recognized` line (same `lineID`).
    case annotated(voice: String?, exchange: Int?)
}

/// What a transcriber reports: words in progress (volatile) or a settled line.
public struct TranscriptionEvent: Equatable, Sendable {
    public var channelID: UUID
    public var text: String
    public var isFinal: Bool
    /// Seconds since the capture session started.
    public var sessionOffset: Double
    public var confidence: Double?
    /// Identifies the line across its stages.
    public var lineID: UUID
    public var stage: LineStage

    public init(
        channelID: UUID, text: String, isFinal: Bool, sessionOffset: Double, confidence: Double?,
        lineID: UUID = UUID(), stage: LineStage = .complete
    ) {
        self.channelID = channelID
        self.text = text
        self.isFinal = isFinal
        self.sessionOffset = sessionOffset
        self.confidence = confidence
        self.lineID = lineID
        self.stage = stage
    }
}

/// The on-screen transcript: settled lines in order, plus each channel's
/// words in progress. Bounded so a long show cannot grow it without limit;
/// the session file keeps everything.
public struct TranscriptTimeline: Sendable {
    public private(set) var segments: [TranscriptSegment] = []
    public private(set) var volatile: [UUID: String] = [:]
    /// The line a channel's volatile text belongs to while it waits for voice
    /// analysis, so the annotation clears that line and not newer words.
    private var awaitingAnnotation: [UUID: UUID] = [:]
    /// Recently recognised lines and their channels, oldest first, so a clear
    /// knows which annotations still on their way belong to lines it removed.
    private var recentLines: [(line: UUID, channel: UUID)] = []
    /// Lines recognised before their channel was cleared, oldest first: their
    /// late annotations go to the session file but not back on screen.
    private var clearedLines: [UUID] = []
    /// How many lines each of those lists remembers. Annotations arrive
    /// within seconds; this covers many channels' worth of waiting lines.
    static let rememberedLines = 512
    public let maximumSegments: Int

    public init(maximumSegments: Int = 5_000) {
        self.maximumSegments = maximumSegments
    }

    /// Applies an event; returns the new segment when a line settles (for the
    /// session file, even when a clear keeps it off screen).
    /// `annotate` adds what automation found (keywords, highlights) before
    /// the line is stored.
    ///
    /// A `.complete` line settles at once. A `.recognized` line shows as the
    /// channel's words in progress until its `.annotated` pieces arrive; each
    /// piece settles as its own segment carrying its voice and exchange.
    @discardableResult
    public mutating func apply(
        _ event: TranscriptionEvent,
        at date: Date,
        annotate: (inout TranscriptSegment) -> Void = { _ in }
    ) -> TranscriptSegment? {
        let text = event.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let channel = event.channelID
        guard event.isFinal else {
            volatile[channel] = Self.hasWords(text) ? text : nil
            awaitingAnnotation[channel] = nil
            return nil
        }
        var voice: String?, exchange: Int?
        switch event.stage {
        case .complete:
            volatile[channel] = nil
            awaitingAnnotation[channel] = nil
        case .recognized:
            volatile[channel] = Self.hasWords(text) ? text : nil
            awaitingAnnotation[channel] = text.isEmpty ? nil : event.lineID
            recentLines.append((event.lineID, channel))
            if recentLines.count > Self.rememberedLines {
                recentLines.removeFirst(recentLines.count - Self.rememberedLines)
            }
            return nil
        case .annotated(let pieceVoice, let pieceExchange):
            if awaitingAnnotation[channel] == event.lineID {
                volatile[channel] = nil
                awaitingAnnotation[channel] = nil
            }
            voice = pieceVoice
            exchange = pieceExchange
        }
        guard !text.isEmpty else { return nil }
        var segment = TranscriptSegment(
            channelID: channel,
            text: text,
            timestamp: date,
            sessionOffset: event.sessionOffset,
            isFinal: true,
            confidence: event.confidence,
            voice: voice,
            exchange: exchange
        )
        annotate(&segment)
        // A line cleared while its voice was worked out stays off screen.
        if case .annotated = event.stage, clearedLines.contains(event.lineID) { return segment }
        segments.append(segment)
        if segments.count > maximumSegments {
            segments.removeFirst(segments.count - maximumSegments)
        }
        return segment
    }

    /// Whether words in progress are worth a row. On a quiet channel the
    /// recogniser can report a lone "." or "…"; text with no letters or
    /// digits would only leave an empty row at the live end.
    static func hasWords(_ text: String) -> Bool {
        text.contains { $0.isLetter || $0.isNumber }
    }

    public func segments(for channelID: UUID) -> [TranscriptSegment] {
        segments.filter { $0.channelID == channelID }
    }

    /// Clears the screen. Lines still waiting for voice analysis are
    /// remembered, so their annotations don't bring them back.
    public mutating func clear(channelID: UUID? = nil) {
        let removed = recentLines.filter { channelID == nil || $0.channel == channelID }
        recentLines.removeAll { channelID == nil || $0.channel == channelID }
        clearedLines.append(contentsOf: removed.map(\.line))
        if clearedLines.count > Self.rememberedLines {
            clearedLines.removeFirst(clearedLines.count - Self.rememberedLines)
        }
        if let channelID {
            segments.removeAll { $0.channelID == channelID }
            volatile[channelID] = nil
            awaitingAnnotation[channelID] = nil
        } else {
            segments = []
            volatile = [:]
            awaitingAnnotation = [:]
        }
    }
}
