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
    /// While speech goes on, the quietest frame in this window is taken as
    /// the background. Speech dips between syllables; steady noise doesn't.
    public var floorWindow: Double = 1.0

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
    /// Frame levels during the current utterance, newest last, up to `floorWindow`.
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
            } else {
                noiseFloor = noiseFloor * 0.95 + rms * 0.05
                preRollBuffer.append(contentsOf: frame)
                let keep = Int(preRoll * sampleRate)
                if preRollBuffer.count > keep { preRollBuffer.removeFirst(preRollBuffer.count - keep) }
            }
            return nil
        }

        current.append(contentsOf: frame)
        learnFloorDuringSpeech(rms)
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

    /// Noise that rises mid-utterance (a comms ring keyed open, a fan, music
    /// bleed) would otherwise count as speech until the maximum length.
    private mutating func learnFloorDuringSpeech(_ rms: Float) {
        let window = max(1, Int(floorWindow / frameSeconds))
        recentLevels.append(rms)
        if recentLevels.count > window { recentLevels.removeFirst(recentLevels.count - window) }
        guard recentLevels.count == window, let quietest = recentLevels.min(), quietest > noiseFloor else { return }
        noiseFloor += (quietest - noiseFloor) * 0.1
    }

    private mutating func finish() -> Utterance? {
        defer {
            recentLevels = []
            inSpeech = false
            current = []
            speechFrames = 0
            silentFrames = 0
        }
        guard Double(speechFrames) * frameSeconds >= minimumSpeech else { return nil }
        return Utterance(samples: current, startOffset: Double(currentStart) / sampleRate)
    }
}
