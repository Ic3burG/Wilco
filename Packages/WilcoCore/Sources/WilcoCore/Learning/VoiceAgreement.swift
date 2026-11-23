import Foundation

/// The speaker-grouping models whose groupings are compared.
public enum ClipDiarizerID {
    public static let pipeline = "offline-pipeline"
    public static let sortformer = "sortformer-offline"
}

/// A stretch of audio one speaker covers, as a speaker-grouping model reports it.
/// Speaker names are whatever the model calls them; only sameness matters.
public struct SpeakerSpan: Equatable, Sendable {
    public var speaker: String
    public var start: Double
    public var end: Double

    public init(speaker: String, start: Double, end: Double) {
        self.speaker = speaker
        self.start = start
        self.end = end
    }
}

/// Groups a channel's kept clips by voice, keeping only the groupings two
/// different speaker-grouping models agree on.
public enum VoiceAgreement {
    /// Where each clip sits when a channel's clips are joined with `gap` seconds of silence between.
    public static func layout(durations: [Double], gap: Double = 1) -> [ClosedRange<Double>] {
        var start = 0.0
        return durations.map { duration in
            let range = start...(start + max(0, duration))
            start = range.upperBound + gap
            return range
        }
    }

    /// The speaker covering most of `range`, or nil if none overlaps.
    /// Every span of the same speaker counts towards it; a tie goes to the
    /// speaker listed first.
    public static func speaker(of range: ClosedRange<Double>, in spans: [SpeakerSpan]) -> String? {
        var order: [String] = []
        var covered: [String: Double] = [:]
        for span in spans {
            let overlap = min(span.end, range.upperBound) - max(span.start, range.lowerBound)
            guard overlap > 0 else { continue }
            if covered[span.speaker] == nil { order.append(span.speaker) }
            covered[span.speaker, default: 0] += overlap
        }
        var best: String?
        for name in order where best == nil || covered[name]! > covered[best!]! {
            best = name
        }
        return best
    }

    /// Per clip: the agreed speaker number, or nil. B's speakers are matched to A's by most
    /// shared clips; a clip agrees when its B speaker maps to its A speaker. Numbers follow
    /// A's speakers in order of first appearance, from 0.
    ///
    /// Matching is one to one, most shared clips first, so when one model splits
    /// a voice the other hears as one, only the larger part agrees. Ties go to
    /// the pair whose A speaker, then B speaker, appears first. A speakers with
    /// no agreed clip get no number, so the numbers have no gaps. Clips past the
    /// end of the shorter list are nil.
    public static func agree(_ a: [String?], _ b: [String?]) -> [Int?] {
        let count = min(a.count, b.count)
        let aOrder = firstAppearance(a.prefix(count))
        let bOrder = firstAppearance(b.prefix(count))

        struct Pair: Hashable { var a: String; var b: String }
        var shared: [Pair: Int] = [:]
        for i in 0..<count {
            guard let x = a[i], let y = b[i] else { continue }
            shared[Pair(a: x, b: y), default: 0] += 1
        }
        let ranked = shared.sorted { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value > rhs.value }
            if lhs.key.a != rhs.key.a { return aOrder[lhs.key.a]! < aOrder[rhs.key.a]! }
            return bOrder[lhs.key.b]! < bOrder[rhs.key.b]!
        }
        var match: [String: String] = [:]  // B speaker -> A speaker
        var usedA: Set<String> = []
        for (pair, _) in ranked where match[pair.b] == nil && !usedA.contains(pair.a) {
            match[pair.b] = pair.a
            usedA.insert(pair.a)
        }

        let agreed = (0..<count).map { i -> String? in
            guard let x = a[i], let y = b[i], match[y] == x else { return nil }
            return x
        }
        var numbers: [String: Int] = [:]
        for name in Set(agreed.compactMap { $0 }).sorted(by: { aOrder[$0]! < aOrder[$1]! }) {
            numbers[name] = numbers.count
        }
        return agreed.map { $0.flatMap { numbers[$0] } } + Array(repeating: nil, count: a.count - count)
    }

    private static func firstAppearance(_ names: ArraySlice<String?>) -> [String: Int] {
        var order: [String: Int] = [:]
        for case let name? in names where order[name] == nil {
            order[name] = order.count
        }
        return order
    }
}
