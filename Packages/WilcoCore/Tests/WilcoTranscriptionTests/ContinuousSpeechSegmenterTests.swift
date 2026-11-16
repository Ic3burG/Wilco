import Foundation
import Testing
@testable import WilcoCore

/// Someone talking without a real pause, on a mic that hears the room. The
/// segmenter must hand nearly all of it to the recogniser.
@Suite("Segmenter with continuous speech")
struct ContinuousSpeechSegmenterTests {
    static let rate = 16_000.0
    static let sentence = "The long form seems to do the live transcription much faster, and it builds better sentences, "
        + "while the other two engines keep dropping whole stretches of what I am saying whenever I talk for a while "
        + "without stopping to take a proper breath between one thought and the next one."

    /// Repeatable hiss, so a failure can be run again.
    struct Hiss: RandomNumberGenerator {
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        mutating func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            var z = state
            z ^= z >> 33
            z = z &* 0xFF51_AFD7_ED55_8CCD
            z ^= z >> 33
            return z
        }
    }

    /// `samples` as a laptop mic in a room hears them: four early echoes
    /// fill the dips between syllables, plus a little hiss.
    static func room(_ samples: [Float], level: Float) -> [Float] {
        let echoes: [(delay: Double, gain: Float)] = [(0.03, 0.5), (0.07, 0.35), (0.13, 0.25), (0.21, 0.15)]
        var out = samples + [Float](repeating: 0, count: Int(0.21 * rate))
        for echo in echoes {
            let shift = Int(echo.delay * rate)
            for index in samples.indices { out[index + shift] += samples[index] * echo.gain }
        }
        var hiss = Hiss()
        return out.map { $0 * level + Float.random(in: -0.002...0.002, using: &hiss) }
    }

    /// The share of `audio` that comes out in utterances.
    static func coverage(of audio: [Float]) -> Double {
        var segmenter = UtteranceSegmenter(sampleRate: rate)
        var utterances = segmenter.append(audio + [Float](repeating: 0, count: Int(rate)))
        if let last = segmenter.flush() { utterances.append(last) }
        let kept = utterances.reduce(0) { $0 + $1.samples.count }
        return Double(kept) / Double(audio.count)
    }

    static let asrTests = ProcessInfo.processInfo.environment["WILCO_ASR_TESTS"] != nil

    @Test(.enabled(if: asrTests), arguments: [Float(0.1), 0.3])
    func continuousRoomSpeechComesThroughNearlyComplete(level: Float) throws {
        let audio = Self.room(try sayClip(Self.sentence), level: level)
        #expect(Double(audio.count) / Self.rate > 9, "the clip should be long, continuous talking")
        let kept = Self.coverage(of: audio)
        #expect(kept >= 0.9, "only \(Int(kept * 100))% of continuous speech reached the recogniser")
    }

    @Test(.enabled(if: asrTests))
    func quietTalkingAfterLoudTalkingIsNotLockedOut() throws {
        let clip = try sayClip(Self.sentence)
        let audio = Self.room(clip, level: 0.3) + Self.room(clip, level: 0.06)
        let kept = Self.coverage(of: audio)
        #expect(kept >= 0.9, "only \(Int(kept * 100))% reached the recogniser after the speaker dropped their voice")
    }
}
