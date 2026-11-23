import Foundation

/// One call on one channel: which clip plays, and when.
public struct ScheduledUtterance: Codable, Equatable, Sendable {
    /// Index into the run's clips.
    public var clip: Int
    /// Seconds from the start of the run.
    public var start: Double
    public var duration: Double
    /// Who says it, in conversation runs: the clip's voice.
    public var voice: Int?
    /// Which exchange on its channel the call belongs to, in conversation
    /// runs. Letters are only compared within one exchange.
    public var exchange: Int?
    /// The level the clip plays at, in long-talk runs. Nil plays it as recorded.
    public var gain: Float?
    /// Seconds into the clip after which the speaker drops their voice to
    /// `Scenario.quietGain`. Nil keeps one level throughout.
    public var quietFrom: Double?
    public var end: Double { start + duration }

    public init(
        clip: Int, start: Double, duration: Double, voice: Int? = nil, exchange: Int? = nil,
        gain: Float? = nil, quietFrom: Double? = nil
    ) {
        self.clip = clip
        self.start = start
        self.duration = duration
        self.voice = voice
        self.exchange = exchange
        self.gain = gain
        self.quietFrom = quietFrom
    }
}

/// What a conversation needs to know about a clip.
public struct ConversationClip: Equatable, Sendable {
    public var duration: Double
    public var voice: Int

    public init(duration: Double, voice: Int) {
        self.duration = duration
        self.voice = voice
    }
}

/// What every channel says during a run. Seeded, so two engines (or two
/// builds) hear exactly the same show.
public struct Scenario: Equatable, Sendable {
    public var duration: Double
    public var dutyCycle: Double
    public var channels: [[ScheduledUtterance]]
    /// A long-talk run: scored on words lost as well as on delay.
    public var longTalk = false
    /// Hiss within ±this under each channel's whole track. 0 for none.
    public var hiss: Float = 0

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

    /// Turns between voices in an exchange: 0.1–0.8 s. Clips from `say` end
    /// with about 0.2 s of their own silence, so the shorter gaps fall under
    /// the segmenter's 0.7 s pause and two voices land in one line.
    public static let turnGap = 0.1...0.8
    /// Quiet between exchanges: longer than the default exchange gap (20 s),
    /// so each exchange starts its letters again from A.
    public static let exchangeQuiet = 25.0...40.0

    /// Each channel holds exchanges of 2–5 turns among 2–4 voices, like a
    /// stage manager calling a cue and departments answering. Neighbouring
    /// turns are always different voices, and voices come back within an
    /// exchange. Only whole exchanges are placed.
    public static func generateConversations(
        channels channelCount: Int, duration: Double, seed: UInt64, clips: [ConversationClip]
    ) -> Scenario {
        let byVoice = Dictionary(grouping: clips.indices) { clips[$0].voice }
        let voices = byVoice.keys.sorted()
        precondition(voices.count >= 2, "a conversation needs at least two voices")
        let channels = (0..<channelCount).map { index -> [ScheduledUtterance] in
            var random = SplitMix64(seed: seed &+ UInt64(index) &* 0x9E37_79B9_7F4A_7C15)
            var time = random.unit() * min(3, duration / 4)
            var exchange = 1
            var utterances: [ScheduledUtterance] = []
            while true {
                // Who's in it, then who speaks each turn.
                var cast = voices
                for i in cast.indices.reversed() { cast.swapAt(i, random.index(below: i + 1)) }
                cast = Array(cast.prefix(min(cast.count, 2 + random.index(below: 3))))
                let turnCount = 2 + random.index(below: 4)
                var speakers = [cast[0], cast[1]]
                while speakers.count < turnCount {
                    let others = cast.filter { $0 != speakers.last }
                    speakers.append(others[random.index(below: others.count)])
                }

                var placed: [ScheduledUtterance] = []
                var at = time
                for (turn, voice) in speakers.enumerated() {
                    if turn > 0 { at += turnGap.lowerBound + random.unit() * (turnGap.upperBound - turnGap.lowerBound) }
                    let options = byVoice[voice]!
                    let clip = options[random.index(below: options.count)]
                    placed.append(ScheduledUtterance(
                        clip: clip, start: at, duration: clips[clip].duration, voice: voice, exchange: exchange
                    ))
                    at += clips[clip].duration
                }
                guard at <= duration - minimumGap else { break }
                utterances += placed
                exchange += 1
                time = at + exchangeQuiet.lowerBound
                    + random.unit() * (exchangeQuiet.upperBound - exchangeQuiet.lowerBound)
            }
            return utterances
        }
        let speech = channels.joined().map(\.duration).reduce(0, +)
        let share = duration > 0 && channelCount > 0 ? speech / (duration * Double(channelCount)) : 0
        return Scenario(duration: duration, dutyCycle: share, channels: channels)
    }

    /// Exchanges from real shows, each placed whole on one channel with its
    /// clips in their original order and gaps (capped at
    /// `RealShowSet.maximumGap`). Exchanges go to the channels in turn, in
    /// order, starting again from the first once all are used, until no
    /// channel has room for its next one. Each placed exchange has its own
    /// number, and `exchangeQuiet` separates exchanges on a channel.
    public static func generateRealExchanges(
        channels channelCount: Int, duration: Double, seed: UInt64, exchanges: [RealExchange], clips: [ConversationClip]
    ) -> Scenario {
        precondition(!exchanges.isEmpty && channelCount > 0)
        var randoms = (0..<channelCount).map { SplitMix64(seed: seed &+ UInt64($0) &* 0x9E37_79B9_7F4A_7C15) }
        var times = randoms.indices.map { randoms[$0].unit() * min(3, duration / 4) }
        var channels = [[ScheduledUtterance]](repeating: [], count: channelCount)
        var full = [Bool](repeating: false, count: channelCount)
        var next = 0
        while full.contains(false) {
            let channel = next % channelCount
            let exchange = exchanges[next % exchanges.count]
            next += 1
            guard !full[channel] else { continue }
            var placed: [ScheduledUtterance] = []
            var at = times[channel]
            for (turn, clip) in exchange.clips.enumerated() {
                if turn > 0 {
                    let gap = turn - 1 < exchange.gaps.count ? exchange.gaps[turn - 1] : 0
                    at += min(RealShowSet.maximumGap, max(0, gap))
                }
                placed.append(ScheduledUtterance(
                    clip: clip, start: at, duration: clips[clip].duration, voice: clips[clip].voice, exchange: next
                ))
                at += clips[clip].duration
            }
            guard at <= duration - minimumGap else {
                full[channel] = true
                continue
            }
            channels[channel] += placed
            times[channel] = at + exchangeQuiet.lowerBound
                + randoms[channel].unit() * (exchangeQuiet.upperBound - exchangeQuiet.lowerBound)
        }
        let speech = channels.joined().map(\.duration).reduce(0, +)
        let share = duration > 0 ? speech / (duration * Double(channelCount)) : 0
        return Scenario(duration: duration, dutyCycle: share, channels: channels)
    }

    /// Quiet between long talks: well over the pause that closes an
    /// utterance, short enough that a channel is mostly talking.
    public static let talkGap = 3.0...8.0
    /// Each channel's own level in a long-talk run, like mics at different gains.
    public static let channelLevel: ClosedRange<Float> = 0.1...0.3
    /// A talk that drops partway starts at `loudGain` and falls to `quietGain`.
    public static let loudGain: Float = 0.3
    public static let quietGain: Float = 0.06

    /// Each channel holds talks of unbroken speech (the clips), `talkGap`
    /// apart, at a level of its own. About one talk in three starts loud and
    /// drops to a quiet voice halfway: a segmenter that learned the loud half
    /// as background would lose the rest. Only whole talks are placed.
    public static func generateLongTalks(
        channels channelCount: Int, clipDurations: [Double], duration: Double, seed: UInt64
    ) -> Scenario {
        precondition(!clipDurations.isEmpty)
        let channels = (0..<channelCount).map { index -> [ScheduledUtterance] in
            var random = SplitMix64(seed: seed &+ UInt64(index) &* 0x9E37_79B9_7F4A_7C15)
            let level = channelLevel.lowerBound
                + Float(random.unit()) * (channelLevel.upperBound - channelLevel.lowerBound)
            var time = random.unit() * min(3, duration / 4)
            var talks: [ScheduledUtterance] = []
            while true {
                let clip = random.index(below: clipDurations.count)
                let length = clipDurations[clip]
                let drops = random.index(below: 3) == 0
                guard time + length <= duration - minimumGap else { break }
                talks.append(ScheduledUtterance(
                    clip: clip, start: time, duration: length,
                    gain: drops ? loudGain : level, quietFrom: drops ? length / 2 : nil
                ))
                time += length + talkGap.lowerBound + random.unit() * (talkGap.upperBound - talkGap.lowerBound)
            }
            return talks
        }
        let speech = channels.joined().map(\.duration).reduce(0, +)
        let share = duration > 0 && channelCount > 0 ? speech / (duration * Double(channelCount)) : 0
        return Scenario(
            duration: duration, dutyCycle: share, channels: channels, longTalk: true, hiss: RoomSound.hissLevel
        )
    }
}

/// A channel's audio, built on demand from its schedule so a long 32-channel
/// run never holds every track in memory.
public struct ChannelTrack: Sendable {
    private struct Placed: Sendable {
        var start: Int
        var clip: Int
        var gain: Float?
        /// Frame of the clip from which it plays at `Scenario.quietGain`.
        var quietFrom: Int?
    }

    private let placed: [Placed]
    private let clips: [[Float]]
    private let hiss: Float
    private let hissSeed: UInt64

    /// `hiss` (±level) runs under the whole track, talking or not, as a
    /// live input's noise does; `hissSeed` makes each channel's its own.
    public init(
        utterances: [ScheduledUtterance], clips: [[Float]], sampleRate: Double, hiss: Float = 0, hissSeed: UInt64 = 0
    ) {
        placed = utterances.map {
            Placed(
                start: Int(($0.start * sampleRate).rounded()), clip: $0.clip, gain: $0.gain,
                quietFrom: $0.quietFrom.map { Int(($0 * sampleRate).rounded()) }
            )
        }
        self.clips = clips
        self.hiss = hiss
        self.hissSeed = hissSeed
    }

    /// `count` samples starting at frame `from`; silence (or hiss) where no one talks.
    public func samples(from: Int, count: Int) -> [Float] {
        var output = [Float](repeating: 0, count: count)
        let end = from + count
        for item in placed {
            let samples = clips[item.clip]
            let clipEnd = item.start + samples.count
            guard item.start < end, clipEnd > from else { continue }
            let lower = max(item.start, from), upper = min(clipEnd, end)
            if item.gain == nil, item.quietFrom == nil {
                for frame in lower..<upper { output[frame - from] = samples[frame - item.start] }
            } else {
                let gain = item.gain ?? 1
                let quietFrom = item.quietFrom ?? .max
                for frame in lower..<upper {
                    let position = frame - item.start
                    output[frame - from] = samples[position] * (position >= quietFrom ? Scenario.quietGain : gain)
                }
            }
        }
        if hiss > 0 {
            for index in 0..<count {
                output[index] += RoomSound.hiss(frame: from + index, seed: hissSeed, level: hiss)
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
