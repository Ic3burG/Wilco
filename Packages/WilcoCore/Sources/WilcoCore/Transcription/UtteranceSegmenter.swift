import Foundation

/// Cuts a continuous mono stream into utterances at pauses.
///
/// Whisper transcribes whole chunks rather than streaming, so a comms channel
/// is split wherever someone stops talking. Speech is detected per 20 ms frame
/// by RMS energy against an adaptive noise floor, which copes with the steady
/// hiss of an open comms ring.
public struct UtteranceSegmenter: Sendable {
    public struct Utterance: Equatable, Sendable {
        public var samples: [Float]
        /// Seconds from the first sample ever appended to the utterance start.
        public var startOffset: Double
    }

    public let sampleRate: Double
    /// Audio kept from just before speech starts, so first syllables survive.
    public var preRoll: Double = 0.3
    /// Silence that ends an utterance.
    public var minimumSilence: Double = 0.7
    /// Utterances are cut here even mid-speech, to bound latency.
    public var maximumLength: Double = 20
    /// Shorter bursts (clicks, keying the mic) are discarded.
    public var minimumSpeech: Double = 0.2
    /// Nothing quieter than this counts as speech (about -46 dBFS).
    public var minimumThreshold: Float = 0.005
    /// The noise floor only rises when this much recent sound was steady.
    public var floorWindow: Double = 1.0
    /// Sound is steady background when its quietest frame in the window is
    /// at least this share of its loud frames (the 90th percentile). Hiss
    /// and hum stay above 0.9. Talking stays under about 0.3, even in a room
    /// whose echoes fill the dips between syllables.
    public var steadiness: Float = 0.5

    private let frameLength: Int
    private var pending: [Float] = []
    private var preRollBuffer: [Float] = []
    private var current: [Float] = []
    private var currentStart = 0
    private var inSpeech = false
    private var speechFrames = 0
    private var silentFrames = 0
    private var processed = 0
    private var noiseFloor: Float = 0.002
    /// The latest frame levels, newest last, up to `floorWindow`.
    private var recentLevels: [Float] = []

    public init(sampleRate: Double) {
        self.sampleRate = sampleRate
        frameLength = max(1, Int(sampleRate * 0.02))
    }

    private var frameSeconds: Double { Double(frameLength) / sampleRate }

    /// Feeds samples; returns any utterances they completed.
    public mutating func append(_ samples: [Float]) -> [Utterance] {
        pending.append(contentsOf: samples)
        var finished: [Utterance] = []
        var index = 0
        while pending.count - index >= frameLength {
            let frame = Array(pending[index..<(index + frameLength)])
            index += frameLength
            if let utterance = process(frame) { finished.append(utterance) }
        }
        pending.removeFirst(index)
        return finished
    }

    /// The utterance being spoken now, as far as it has got (pre-roll
    /// included), or nil between utterances. For previews; it is not cut.
    public var inProgress: Utterance? {
        guard inSpeech else { return nil }
        return Utterance(samples: current, startOffset: Double(currentStart) / sampleRate)
    }

    /// Seconds of speech heard in the utterance in progress (0 between
    /// utterances): pre-roll and pauses don't count.
    public var speechInProgress: Double {
        inSpeech ? Double(speechFrames) * frameSeconds : 0
    }

    /// How long the utterance in progress has been quiet: the pause that
    /// may be about to end it. 0 while someone talks or between utterances.
    public var silenceInProgress: Double {
        inSpeech ? Double(silentFrames) * frameSeconds : 0
    }

    /// Ends any utterance in progress, for when capture stops.
    public mutating func flush() -> Utterance? {
        guard inSpeech else { return nil }
        return finish()
    }

    private mutating func process(_ frame: [Float]) -> Utterance? {
        let rms = (frame.reduce(0) { $0 + $1 * $1 } / Float(frame.count)).squareRoot()
        let isSpeech = rms > max(minimumThreshold, noiseFloor * 4)
        let frameStart = processed
        processed += frame.count

        guard inSpeech else {
            if isSpeech {
                inSpeech = true
                currentStart = frameStart - preRollBuffer.count
                current = preRollBuffer + frame
                preRollBuffer = []
                speechFrames = 1
                silentFrames = 0
                learnFloor(rms)
            } else {
                learnFloor(rms)
                preRollBuffer.append(contentsOf: frame)
                let keep = Int(preRoll * sampleRate)
                if preRollBuffer.count > keep { preRollBuffer.removeFirst(preRollBuffer.count - keep) }
            }
            return nil
        }

        current.append(contentsOf: frame)
        learnFloor(rms)
        if isSpeech {
            speechFrames += 1
            silentFrames = 0
        } else {
            silentFrames += 1
        }

        if Double(silentFrames) * frameSeconds >= minimumSilence {
            return finish()
        }
        if Double(current.count) / sampleRate >= maximumLength {
            let utterance = finish()
            // Speech is still going: carry straight on into the next chunk.
            inSpeech = true
            currentStart = processed
            speechFrames = 0
            return utterance
        }
        return nil
    }

    /// Between utterances the floor falls freely. It rises, in or out of an
    /// utterance, only towards steady sound. Noise that starts mid-utterance
    /// (a comms ring keyed open, a fan) is steady, so it is learned and the
    /// utterance can end. Talking is not: learning its dips as background
    /// would put the speech itself under the threshold.
    private mutating func learnFloor(_ rms: Float) {
        let window = max(1, Int(floorWindow / frameSeconds))
        recentLevels.append(rms)
        if recentLevels.count > window { recentLevels.removeFirst(recentLevels.count - window) }
        if !inSpeech, rms < noiseFloor {
            noiseFloor = noiseFloor * 0.95 + rms * 0.05
            return
        }
        guard recentLevels.count == window else { return }
        let sorted = recentLevels.sorted()
        let quietest = sorted[0], loud = sorted[(window * 9) / 10]
        guard quietest > noiseFloor, quietest >= steadiness * loud else { return }
        noiseFloor += (quietest - noiseFloor) * 0.1
    }

    private mutating func finish() -> Utterance? {
        defer {
            inSpeech = false
            current = []
            speechFrames = 0
            silentFrames = 0
        }
        guard Double(speechFrames) * frameSeconds >= minimumSpeech else { return nil }
        return Utterance(samples: current, startOffset: Double(currentStart) / sampleRate)
    }
}
