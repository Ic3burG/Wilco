import Foundation
import Testing
import WilcoBench
@testable import WilcoCore

/// Someone talking without a real pause, on a mic that hears the room. The
/// segmenter must hand nearly all of it to the recogniser.
@Suite("Segmenter with continuous speech")
struct ContinuousSpeechSegmenterTests {
    static let rate = 16_000.0
    static let sentence = ClipLibrary.passages[0]

    /// `samples` as a laptop mic in a room hears them: early echoes fill the
    /// dips between syllables, plus a little hiss.
    static func room(_ samples: [Float], level: Float) -> [Float] {
        RoomSound.echoed(samples, sampleRate: rate).enumerated().map {
            $1 * level + RoomSound.hiss(frame: $0, seed: 1)
        }
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
