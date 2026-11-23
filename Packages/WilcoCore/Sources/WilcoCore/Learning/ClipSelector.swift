import Foundation

/// Limits for choosing which finished lines keep their audio as clips.
public enum ClipThresholds {
    /// A line is unclear when its confidence is below this percentile of the channel's earlier lines.
    public static let unclearPercentile = 0.25, warmupLines = 20, warmupConfidence = 0.75
    /// Back-to-back lines: each starts within `exchangeGap` seconds of the previous line's end.
    public static let exchangeGap = 10.0, exchangeMinimumLines = 3, exchangeMaximumLines = 12
    /// Lines shorter than the minimum, or at least the maximum, are skipped.
    public static let minimumDuration = 0.5, maximumDuration = 19.5
    /// Per session.
    public static let unclearCap = 100, exchangeCap = 20
}

/// A finished transcript line offered for keeping.
public struct ClipCandidate: Equatable, Sendable {
    public var id: UUID
    public var channel: UUID
    public var sessionOffset: Double
    public var duration: Double
    public var confidence: Double?

    public init(id: UUID = UUID(), channel: UUID, sessionOffset: Double, duration: Double, confidence: Double?) {
        self.id = id
        self.channel = channel
        self.sessionOffset = sessionOffset
        self.duration = duration
        self.confidence = confidence
    }
}

/// What to do with a line's audio.
public enum ClipChange: Equatable, Sendable {
    /// Keep the audio in memory for now.
    case hold(UUID)
    /// Write it (or update its record if already written).
    case keep(UUID, ClipKind, exchange: Int?)
    /// Delete the file or drop the held audio.
    case remove(UUID)
}

/// Decides which lines to keep as clips: unclear lines, and back-to-back exchanges on one
/// channel. Each kind is spread over the whole session by reservoir sampling, so a long
/// session keeps lines from its end as well as its start.
public struct ClipSelector: Sendable {
    private struct Channel {
        var confidences: [Double] = []
        var run: [ClipCandidate] = []
        /// A skipped line broke the run; it closes before the next line joins.
        var broken = false
    }

    private let unclearCap: Int
    private let exchangeCap: Int
    private let random: @Sendable (Int) -> Int

    private var channels: [UUID: Channel] = [:]
    /// Ids in open runs.
    private var held: Set<UUID> = []

    private var unclearKept: [UUID] = []
    private var unclearSeen = 0
    /// Lines replaced in the unclear reservoir while still held; removed when their run closes.
    private var removeWhenReleased: Set<UUID> = []

    private var exchangesKept: [[UUID]] = []
    private var exchangesSeen = 0
    private var exchangeNumber = 0

    public init(
        unclearCap: Int = ClipThresholds.unclearCap, exchangeCap: Int = ClipThresholds.exchangeCap,
        random: @escaping @Sendable (Int) -> Int = { Int.random(in: 0..<$0) }
    ) {
        self.unclearCap = unclearCap
        self.exchangeCap = exchangeCap
        self.random = random
    }

    /// `samplesEmpty` true when the line's audio couldn't be fetched.
    public mutating func offer(_ line: ClipCandidate, samplesEmpty: Bool = false) -> [ClipChange] {
        if samplesEmpty || line.duration < ClipThresholds.minimumDuration
            || line.duration >= ClipThresholds.maximumDuration {
            channels[line.channel, default: Channel()].broken = true
            return []
        }

        var removals: [ClipChange] = []
        var keeps: [ClipChange] = []
        var state = channels[line.channel] ?? Channel()

        if let previous = state.run.last,
           state.broken || line.sessionOffset > previous.sessionOffset + previous.duration + ClipThresholds.exchangeGap {
            close(state.run, removals: &removals, keeps: &keeps)
            state.run = []
        }
        state.broken = false

        let unclear = isUnclear(line.confidence, history: state.confidences)
        if let confidence = line.confidence { state.confidences.append(confidence) }

        state.run.append(line)
        held.insert(line.id)

        if unclear && offerUnclear(line.id, removals: &removals) {
            keeps.append(.keep(line.id, .unclear, exchange: nil))
        }

        var hold: [ClipChange] = [.hold(line.id)]
        if state.run.count >= ClipThresholds.exchangeMaximumLines {
            // The line closing the run is never held, so it needs no removal if the run isn't kept.
            close(state.run, unheld: line.id, removals: &removals, keeps: &keeps)
            state.run = []
            hold = []
        }
        channels[line.channel] = state
        return removals + keeps + hold
    }

    /// Closes every open run (capture stopped).
    public mutating func finish() -> [ClipChange] {
        var removals: [ClipChange] = []
        var keeps: [ClipChange] = []
        for id in channels.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard var state = channels[id] else { continue }
            if !state.run.isEmpty { close(state.run, removals: &removals, keeps: &keeps) }
            state.run = []
            state.broken = false
            channels[id] = state
        }
        return removals + keeps
    }

    private func isUnclear(_ confidence: Double?, history: [Double]) -> Bool {
        guard let confidence else { return true }
        guard history.count >= ClipThresholds.warmupLines else { return confidence < ClipThresholds.warmupConfidence }
        // Nearest-rank percentile of the earlier lines.
        let sorted = history.sorted()
        let rank = max(1, Int((ClipThresholds.unclearPercentile * Double(sorted.count)).rounded(.up)))
        return confidence < sorted[rank - 1]
    }

    /// Algorithm R over unclear lines; free slots (left by lines taken into exchanges) fill first.
    /// Refilling freed slots slightly favours later lines; accepted.
    private mutating func offerUnclear(_ id: UUID, removals: inout [ClipChange]) -> Bool {
        unclearSeen += 1
        if unclearKept.count < unclearCap {
            unclearKept.append(id)
            return true
        }
        let slot = random(unclearSeen)
        guard slot < unclearCap else { return false }
        let replaced = unclearKept[slot]
        unclearKept[slot] = id
        if held.contains(replaced) {
            removeWhenReleased.insert(replaced)
        } else {
            removals.append(.remove(replaced))
        }
        return true
    }

    private mutating func close(
        _ run: [ClipCandidate], unheld: UUID? = nil, removals: inout [ClipChange], keeps: inout [ClipChange]
    ) {
        let ids = run.map(\.id)
        for id in ids { held.remove(id) }
        defer { for id in ids { removeWhenReleased.remove(id) } }

        if ids.count >= ClipThresholds.exchangeMinimumLines, offerExchange(ids, removals: &removals) {
            exchangeNumber += 1
            keeps += ids.map { .keep($0, .exchange, exchange: exchangeNumber) }
            let taken = Set(ids)
            unclearKept.removeAll { taken.contains($0) }
            return
        }
        let unclear = Set(unclearKept)
        removals += ids.filter { !unclear.contains($0) && $0 != unheld }.map { .remove($0) }
    }

    /// Algorithm R over exchanges, counted in runs.
    private mutating func offerExchange(_ ids: [UUID], removals: inout [ClipChange]) -> Bool {
        exchangesSeen += 1
        if exchangesKept.count < exchangeCap {
            exchangesKept.append(ids)
            return true
        }
        let slot = random(exchangesSeen)
        guard slot < exchangeCap else { return false }
        removals += exchangesKept[slot].map { .remove($0) }
        exchangesKept[slot] = ids
        return true
    }
}
