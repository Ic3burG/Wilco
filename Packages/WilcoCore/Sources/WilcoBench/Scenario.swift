import Foundation

/// One call on one channel: which clip plays, and when.
public struct ScheduledUtterance: Codable, Equatable, Sendable {
    /// Index into the run's clips.
    public var clip: Int
    /// Seconds from the start of the run.
    public var start: Double
    public var duration: Double
    public var end: Double { start + duration }

    public init(clip: Int, start: Double, duration: Double) {
        self.clip = clip
        self.start = start
        self.duration = duration
    }
}

/// What every channel says during a run. Seeded, so two engines (or two
/// builds) hear exactly the same show.
public struct Scenario: Equatable, Sendable {
    public var duration: Double
    public var dutyCycle: Double
    public var channels: [[ScheduledUtterance]]

    /// Silence between calls. Longer than the pause that closes an utterance
    /// (0.7 s) plus the transcribers' 100 ms pump, so each call stands alone.
    public static let minimumGap = 1.2

    public var speechSeconds: Double { channels.joined().map(\.duration).reduce(0, +) }
    public var utteranceCount: Int { channels.map(\.count).reduce(0, +) }

    /// Each channel talks for about `dutyCycle` of the time, at moments of
    /// its own, like a comms ring where people key in independently.
    public static func generate(
        channelCount: Int, clipDurations: [Double], duration: Double, dutyCycle: Double, seed: UInt64
    ) -> Scenario {
        precondition(!clipDurations.isEmpty && dutyCycle > 0 && dutyCycle < 1)
        let channels = (0..<channelCount).map { index -> [ScheduledUtterance] in
            var random = SplitMix64(seed: seed &+ UInt64(index) &* 0x9E37_79B9_7F4A_7C15)
            var time = random.unit() * min(3, duration / 4)
            var utterances: [ScheduledUtterance] = []
            while true {
                let clip = random.index(below: clipDurations.count)
                let length = clipDurations[clip]
                guard time + length <= duration - minimumGap else { break }
                utterances.append(ScheduledUtterance(clip: clip, start: time, duration: length))
                let meanGap = length * (1 - dutyCycle) / dutyCycle
                time += length + max(minimumGap, meanGap * (0.5 + random.unit()))
            }
            return utterances
        }
        return Scenario(duration: duration, dutyCycle: dutyCycle, channels: channels)
    }
}

/// A channel's audio, built on demand from its schedule so a long 32-channel
/// run never holds every track in memory.
public struct ChannelTrack: Sendable {
    private let placed: [(start: Int, clip: Int)]
    private let clips: [[Float]]

    public init(utterances: [ScheduledUtterance], clips: [[Float]], sampleRate: Double) {
        placed = utterances.map { (Int(($0.start * sampleRate).rounded()), $0.clip) }
        self.clips = clips
    }

    /// `count` samples starting at frame `from`; silence where no one talks.
    public func samples(from: Int, count: Int) -> [Float] {
        var output = [Float](repeating: 0, count: count)
        let end = from + count
        for (start, clip) in placed {
            let samples = clips[clip]
            let clipEnd = start + samples.count
            guard start < end, clipEnd > from else { continue }
            let lower = max(start, from), upper = min(clipEnd, end)
            for frame in lower..<upper {
                output[frame - from] = samples[frame - start]
            }
        }
        return output
    }
}

/// Small, fast and reproducible on every machine, unlike the system RNG.
struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in [0, 1).
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }

    mutating func index(below count: Int) -> Int { Int(next() % UInt64(count)) }
}
