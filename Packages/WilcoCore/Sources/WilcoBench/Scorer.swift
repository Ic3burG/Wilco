import Foundation
import WilcoCore

/// A transcription event as the benchmark saw it arrive.
public struct ObservedEvent: Equatable, Sendable {
    public var text: String
    public var isFinal: Bool
    /// Where the engine says the words began, in run seconds.
    public var sessionOffset: Double
    /// When the event reached us, in run seconds.
    public var arrival: Double
    public var stage: LineStage

    public init(text: String, isFinal: Bool, sessionOffset: Double, arrival: Double, stage: LineStage = .complete) {
        self.text = text
        self.isFinal = isFinal
        self.sessionOffset = sessionOffset
        self.arrival = arrival
        self.stage = stage
    }

    /// A final line as rules see it: `.complete` or `.recognized`. Each line
    /// is counted once, so its `.annotated` pieces are not.
    var isRuleLine: Bool {
        guard isFinal else { return false }
        if case .annotated = stage { return false }
        return true
    }

    /// A final line as the transcript shows it: `.complete` or `.annotated`.
    var isDisplayLine: Bool {
        isFinal && stage != .recognized
    }
}

/// How one channel came out.
public struct ChannelScore: Equatable, Sendable {
    public var wordErrors: WordErrors
    /// Per answered utterance: seconds from the end of speech to its last
    /// final line (`.complete` or `.recognized`, when rules can act on it).
    public var finalLatencies: [Double]
    /// Per displayed utterance: seconds from the end of speech to its last
    /// line on screen (`.complete` or `.annotated`). Equals the final delay
    /// when lines aren't annotated.
    public var displayLatencies: [Double]
    /// Per answered utterance: seconds from the start of speech to the first words shown.
    public var firstWordLatencies: [Double]
    /// Utterances no final line was attributed to.
    public var missed: Int
    public var reference: String
    public var hypothesis: String
}

public enum Scorer {
    /// Lines are matched to calls by where the engine says they started.
    /// Words are scored over the whole channel instead, so an engine that
    /// merges or splits lines differently isn't penalised for that alone.
    public static func score(utterances: [ScheduledUtterance], texts: [String], events: [ObservedEvent]) -> ChannelScore {
        var finalArrivals = [[Double]](repeating: [], count: utterances.count)
        var displayArrivals = [[Double]](repeating: [], count: utterances.count)
        var firstArrival = [Double?](repeating: nil, count: utterances.count)
        for event in events {
            guard let index = utterance(for: event.sessionOffset, in: utterances) else { continue }
            if event.isRuleLine { finalArrivals[index].append(event.arrival) }
            if event.isDisplayLine { displayArrivals[index].append(event.arrival) }
            firstArrival[index] = min(firstArrival[index] ?? .infinity, event.arrival)
        }

        var finalLatencies: [Double] = []
        var displayLatencies: [Double] = []
        var firstWordLatencies: [Double] = []
        var missed = 0
        for (index, utterance) in utterances.enumerated() {
            if let last = finalArrivals[index].max() {
                finalLatencies.append(last - utterance.end)
            } else {
                missed += 1
            }
            if let last = displayArrivals[index].max() {
                displayLatencies.append(last - utterance.end)
            }
            if let first = firstArrival[index] {
                firstWordLatencies.append(first - utterance.start)
            }
        }

        let reference = utterances.map { texts[$0.clip] }.joined(separator: " ")
        let hypothesis = events.filter(\.isRuleLine)
            .sorted { ($0.sessionOffset, $0.arrival) < ($1.sessionOffset, $1.arrival) }
            .map(\.text).joined(separator: " ")
        return ChannelScore(
            wordErrors: WordErrorRate.compare(
                reference: TranscriptNormalizer.words(reference),
                hypothesis: TranscriptNormalizer.words(hypothesis)
            ),
            finalLatencies: finalLatencies,
            displayLatencies: displayLatencies,
            firstWordLatencies: firstWordLatencies,
            missed: missed,
            reference: reference,
            hypothesis: hypothesis
        )
    }

    /// The call a line belongs to: one whose span (with a little slack for
    /// engines that place the start early or late) holds the line's start.
    static func utterance(for offset: Double, in utterances: [ScheduledUtterance]) -> Int? {
        var best: (index: Int, distance: Double)?
        for (index, utterance) in utterances.enumerated()
        where offset >= utterance.start - 1.0 && offset <= utterance.end + 0.5 {
            let distance = abs(utterance.start - offset)
            if distance < best?.distance ?? .infinity { best = (index, distance) }
        }
        return best?.index
    }
}

/// Spread of a set of delays, in seconds.
public struct LatencySummary: Codable, Equatable, Sendable {
    public var p50: Double
    public var p95: Double
    public var max: Double
    public var mean: Double

    public init?(_ values: [Double]) {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        func percentile(_ p: Double) -> Double {
            sorted[Swift.max(0, Int((p * Double(sorted.count)).rounded(.up)) - 1)]
        }
        p50 = percentile(0.5)
        p95 = percentile(0.95)
        max = sorted.last!
        mean = values.reduce(0, +) / Double(values.count)
    }
}
