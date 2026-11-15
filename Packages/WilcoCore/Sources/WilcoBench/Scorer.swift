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
    /// Ties a `.recognized` line to its `.annotated` pieces.
    public var lineID: UUID
    public var stage: LineStage

    public init(
        text: String, isFinal: Bool, sessionOffset: Double, arrival: Double, lineID: UUID = UUID(),
        stage: LineStage = .complete
    ) {
        self.text = text
        self.isFinal = isFinal
        self.sessionOffset = sessionOffset
        self.arrival = arrival
        self.lineID = lineID
        self.stage = stage
    }

    /// The letter and exchange of an `.annotated` piece; nil otherwise.
    var annotation: (voice: String?, exchange: Int?)? {
        guard isFinal, case .annotated(let voice, let exchange) = stage else { return nil }
        return (voice, exchange)
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
    /// Per answered utterance (or run of merged ones): seconds from the end
    /// of speech to its last final line (`.complete` or `.recognized`, when
    /// rules can act on it).
    public var finalLatencies: [Double]
    /// Per displayed utterance (or run of merged ones): seconds from the end of speech to its last
    /// line on screen (`.complete` or `.annotated`). Equals the final delay
    /// when lines aren't annotated.
    public var displayLatencies: [Double]
    /// Per answered utterance: seconds from the start of speech to the first words shown.
    public var firstWordLatencies: [Double]
    /// Utterances no final line was attributed to.
    public var missed: Int
    /// Calls with no line of their own, answered by the previous call's line
    /// because they followed it too closely to be cut apart.
    public var merged: Int = 0
    /// `.recognized` lines whose `.annotated` form never arrived.
    public var missingAnnotations: Int = 0
    public var reference: String
    public var hypothesis: String
}

/// How well one channel's (or a run's) lines were given voice letters.
/// Only conversation runs have voice changes to find.
public struct VoiceScore: Codable, Equatable, Sendable {
    /// Turn boundaries where the voice changes, within an exchange.
    public var changes: Int
    /// Of those, ones with no change of letter within ±0.5 s.
    public var missedChanges: Int
    /// Changes of letter with no change of voice within ±0.5 s.
    public var falseChanges: Int
    /// Turns by a voice already heard earlier in the exchange, whose first
    /// turn got a letter.
    public var returningTurns: Int
    /// Of those, turns shown with the voice's earlier letter.
    public var correctLetters: Int
    /// Annotated pieces.
    public var lines: Int
    /// Annotated pieces without a letter: too little audio, no match for a
    /// short line, no voice model, or the channel's voice queue was full.
    public var unlettered: Int
    /// Recognised lines whose annotation never arrived.
    public var missingAnnotations: Int

    public init(
        changes: Int = 0, missedChanges: Int = 0, falseChanges: Int = 0, returningTurns: Int = 0,
        correctLetters: Int = 0, lines: Int = 0, unlettered: Int = 0, missingAnnotations: Int = 0
    ) {
        self.changes = changes
        self.missedChanges = missedChanges
        self.falseChanges = falseChanges
        self.returningTurns = returningTurns
        self.correctLetters = correctLetters
        self.lines = lines
        self.unlettered = unlettered
        self.missingAnnotations = missingAnnotations
    }

    /// Share of returning turns that got their earlier letter back.
    public var letterAccuracy: Double? {
        returningTurns > 0 ? Double(correctLetters) / Double(returningTurns) : nil
    }

    public static func + (a: VoiceScore, b: VoiceScore) -> VoiceScore {
        VoiceScore(
            changes: a.changes + b.changes, missedChanges: a.missedChanges + b.missedChanges,
            falseChanges: a.falseChanges + b.falseChanges, returningTurns: a.returningTurns + b.returningTurns,
            correctLetters: a.correctLetters + b.correctLetters, lines: a.lines + b.lines,
            unlettered: a.unlettered + b.unlettered, missingAnnotations: a.missingAnnotations + b.missingAnnotations
        )
    }
}

public enum Scorer {
    /// Lines are matched to calls by where the engine says they started.
    /// Words are scored over the whole channel instead, so an engine that
    /// merges or splits lines differently isn't penalised for that alone.
    ///
    /// A `.recognized` line whose annotation never came counts on screen at
    /// `watchedUntil` (when the run stopped listening), a lower bound on its
    /// delay; without `watchedUntil` it's only counted.
    public static func score(
        utterances: [ScheduledUtterance], texts: [String], events: [ObservedEvent], watchedUntil: Double? = nil
    ) -> ChannelScore {
        var finalArrivals = [[Double]](repeating: [], count: utterances.count)
        var displayArrivals = [[Double]](repeating: [], count: utterances.count)
        var firstArrival = [Double?](repeating: nil, count: utterances.count)
        let lost = unannotated(events)
        for event in events {
            guard let index = utterance(for: event.sessionOffset, in: utterances) else { continue }
            if event.isRuleLine { finalArrivals[index].append(event.arrival) }
            if event.isDisplayLine { displayArrivals[index].append(event.arrival) }
            if let watchedUntil, lost.contains(event.lineID), event.stage == .recognized {
                displayArrivals[index].append(watchedUntil)
            }
            firstArrival[index] = min(firstArrival[index] ?? .infinity, event.arrival)
        }

        // A call with no line of its own that follows the previous one closer
        // than any pause the segmenter could cut at was merged into the
        // previous call's line. That line answers both, and its delay runs
        // from the end of the last call in it.
        var groups: [(first: Int, last: Int)] = []
        var missed = 0, merged = 0
        for index in utterances.indices {
            if !finalArrivals[index].isEmpty {
                groups.append((index, index))
            } else if let group = groups.last, group.last == index - 1,
                      utterances[index].start - utterances[index - 1].end < Scenario.minimumGap {
                groups[groups.count - 1].last = index
                merged += 1
            } else {
                missed += 1
            }
        }

        var finalLatencies: [Double] = []
        var displayLatencies: [Double] = []
        var firstWordLatencies: [Double] = []
        for group in groups {
            let end = utterances[group.last].end
            let members = group.first...group.last
            if let last = members.flatMap({ finalArrivals[$0] }).max() { finalLatencies.append(last - end) }
            if let last = members.flatMap({ displayArrivals[$0] }).max() { displayLatencies.append(last - end) }
        }
        for (index, utterance) in utterances.enumerated() {
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
            merged: merged,
            missingAnnotations: lost.count,
            reference: reference,
            hypothesis: hypothesis
        )
    }

    /// Recognised lines with no annotated piece.
    static func unannotated(_ events: [ObservedEvent]) -> Set<UUID> {
        let annotated = Set(events.filter { $0.annotation != nil }.map(\.lineID))
        return Set(events.filter { $0.isFinal && $0.stage == .recognized && !annotated.contains($0.lineID) }.map(\.lineID))
    }

    /// Turns are a conversation's scheduled calls with a voice and an
    /// exchange; pieces are the `.annotated` events, in session order.
    ///
    /// A piece changes voice when its letter differs from the last lettered
    /// piece in the same exchange. A turn's letter is the one on screen just
    /// after it starts: that of the last piece starting by 0.5 s into it.
    public static func scoreVoices(utterances: [ScheduledUtterance], events: [ObservedEvent]) -> VoiceScore {
        let tolerance = 0.5
        let pieces = events.filter { $0.annotation != nil }.sorted { $0.sessionOffset < $1.sessionOffset }
        var score = VoiceScore()
        score.lines = pieces.count
        score.unlettered = pieces.filter { $0.annotation?.voice == nil }.count
        score.missingAnnotations = unannotated(events).count

        // Where the letter changes.
        var found: [Double] = []
        var last: (voice: String, exchange: Int?)?
        for piece in pieces {
            guard let annotation = piece.annotation, let voice = annotation.voice else { continue }
            if let last, last.exchange == annotation.exchange, last.voice != voice { found.append(piece.sessionOffset) }
            last = (voice, annotation.exchange)
        }

        // Where the voice changes, and what each turn was shown as.
        let turns = utterances.filter { $0.voice != nil && $0.exchange != nil }.sorted { $0.start < $1.start }
        var actual: [Double] = []
        var firstLetter: [Int: String?] = [:]
        var exchangeStart = 0.0
        for (i, turn) in turns.enumerated() {
            let previous = i > 0 ? turns[i - 1] : nil
            if previous?.exchange != turn.exchange {
                firstLetter = [:]
                exchangeStart = turn.start
            } else if previous?.voice != turn.voice {
                actual.append(turn.start)
            }
            let shown = pieces.last {
                $0.sessionOffset <= turn.start + tolerance && $0.sessionOffset >= exchangeStart - 1.0
            }?.annotation?.voice
            if let earlier = firstLetter[turn.voice!] {
                if let earlier {
                    score.returningTurns += 1
                    if shown == earlier { score.correctLetters += 1 }
                }
            } else {
                firstLetter[turn.voice!] = .some(shown)
            }
        }

        // Pair each change with the nearest unclaimed letter change.
        score.changes = actual.count
        var unclaimed = found
        for time in actual {
            let nearest = unclaimed.indices.min { abs(unclaimed[$0] - time) < abs(unclaimed[$1] - time) }
            if let nearest, abs(unclaimed[nearest] - time) <= tolerance {
                unclaimed.remove(at: nearest)
            } else {
                score.missedChanges += 1
            }
        }
        score.falseChanges = unclaimed.count
        return score
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
