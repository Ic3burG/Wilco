import Foundation
import Testing
@testable import WilcoCore

@Suite("Utterance segmenter")
struct UtteranceSegmenterTests {
    private let rate = 16_000.0

    private func tone(_ seconds: Double, amplitude: Float = 0.3) -> [Float] {
        (0..<Int(seconds * rate)).map { amplitude * sin(Float($0) * 2 * .pi * 440 / Float(rate)) }
    }

    /// Speech-like: 200 ms syllables with 80 ms dips between them, as in
    /// continuous talking. A steady tone would be learned as background.
    private func syllables(_ seconds: Double, amplitude: Float = 0.3) -> [Float] {
        let on = Int(0.2 * rate), period = Int(0.28 * rate)
        return (0..<Int(seconds * rate)).map { i in
            i % period < on ? amplitude * sin(Float(i) * 2 * .pi * 440 / Float(rate)) : 0.002
        }
    }

    private func silence(_ seconds: Double) -> [Float] {
        [Float](repeating: 0, count: Int(seconds * rate))
    }

    @Test func emitsAnUtteranceAfterAPause() {
        var segmenter = UtteranceSegmenter(sampleRate: rate)
        var utterances = segmenter.append(silence(1) + tone(1.5))
        #expect(utterances.isEmpty)

        utterances = segmenter.append(silence(1))

        let utterance = try! #require(utterances.first)
        #expect(utterances.count == 1)
        // Starts just before the speech, with pre-roll.
        #expect(abs(utterance.startOffset - (1 - segmenter.preRoll)) < 0.05)
        let seconds = Double(utterance.samples.count) / rate
        #expect(seconds > 1.5 && seconds < 2.6)
    }

    @Test func silenceAloneEmitsNothing() {
        var segmenter = UtteranceSegmenter(sampleRate: rate)
        #expect(segmenter.append(silence(5)).isEmpty)
    }

    @Test func longSpeechIsCutAtTheMaximum() {
        var segmenter = UtteranceSegmenter(sampleRate: rate)
        let utterances = segmenter.append(syllables(segmenter.maximumLength + 1))
        #expect(utterances.count == 1)
        let seconds = Double(utterances[0].samples.count) / rate
        // Cut at the maximum, not earlier: continuous talking isn't noise.
        #expect(seconds >= segmenter.maximumLength - 0.1)
        #expect(seconds <= segmenter.maximumLength + segmenter.preRoll + 0.05)
    }

    @Test func steadyToneIsLearnedAsBackground() {
        var segmenter = UtteranceSegmenter(sampleRate: rate)
        let utterances = segmenter.append(tone(8))
        #expect(utterances.count == 1)
        #expect(Double(utterances[0].samples.count) / rate < 4)
    }

    /// Background noise that rises while someone is talking (an open comms
    /// ring, a fan, music bleed) must not hold the utterance open to the
    /// maximum length: the noise floor has to keep learning during speech.
    @Test func noiseThatStartsMidSpeechStillEndsTheUtterance() {
        var segmenter = UtteranceSegmenter(sampleRate: rate)
        var generator = SystemRandomNumberGenerator()
        let hiss = (0..<Int(10 * rate)).map { _ in Float.random(in: -0.03...0.03, using: &generator) }
        let utterances = segmenter.append(silence(1) + tone(2) + hiss)
        let first = try! #require(utterances.first, "no utterance within 10 s of steady noise")
        #expect(Double(first.samples.count) / rate < 6, "held open by noise: \(Double(first.samples.count) / rate) s")
    }

    @Test func flushReturnsSpeechInProgress() {
        var segmenter = UtteranceSegmenter(sampleRate: rate)
        _ = segmenter.append(tone(1))
        #expect(segmenter.flush() != nil)
        #expect(segmenter.flush() == nil)
    }
}

@Suite("Recogniser vocabulary")
struct VocabularyTests {
    @Test func mergesShowChannelAndRulePhrasesWithoutDuplicates() {
        var show = ShowDocument()
        let channel = show.addChannel()
        let other = show.addChannel()
        show.globalVocabulary = ["Standby", "Pyro"]
        show.updateChannel(id: channel.id) { $0.vocabulary = ["Omar", "pyro"] }
        show.rules = [
            AutomationRule(name: "All", phrases: ["go"]),
            AutomationRule(name: "Other only", phrases: ["house out"], channelIDs: [other.id]),
            AutomationRule(name: "Off", isEnabled: false, phrases: ["disabled"]),
        ]
        show.highlights = [HighlightRule(name: "Names", phrases: ["Triad"], channelIDs: [channel.id])]

        #expect(show.vocabulary(for: channel.id) == ["Standby", "Pyro", "Omar", "go", "Triad"])
    }
}

@Suite("Transcript timeline")
struct TranscriptTimelineTests {
    private let a = UUID(), b = UUID()

    private func event(_ channel: UUID, _ text: String, final: Bool, at offset: Double = 0) -> TranscriptionEvent {
        TranscriptionEvent(channelID: channel, text: text, isFinal: final, sessionOffset: offset, confidence: nil)
    }

    @Test func volatileTextIsReplacedThenCleared() {
        var timeline = TranscriptTimeline()
        timeline.apply(event(a, "stand", final: false), at: .now)
        timeline.apply(event(a, "standby lx", final: false), at: .now)
        #expect(timeline.volatile[a] == "standby lx")
        #expect(timeline.segments.isEmpty)

        let segment = timeline.apply(event(a, "Standby LX 5.", final: true), at: .now)

        #expect(segment?.text == "Standby LX 5.")
        #expect(timeline.volatile[a] == nil)
        #expect(timeline.segments.map(\.text) == ["Standby LX 5."])
    }

    @Test func annotationIsStoredWithTheLine() {
        var timeline = TranscriptTimeline()
        let segment = timeline.apply(event(a, "Standby", final: true), at: .now) { $0.matchedKeywords = ["standby"] }
        #expect(segment?.matchedKeywords == ["standby"])
        #expect(timeline.segments.first?.matchedKeywords == ["standby"])
    }

    @Test func blankFinalsAreDropped() {
        var timeline = TranscriptTimeline()
        timeline.apply(event(a, "um", final: false), at: .now)
        #expect(timeline.apply(event(a, "  ", final: true), at: .now) == nil)
        #expect(timeline.volatile[a] == nil)
        #expect(timeline.segments.isEmpty)
    }

    @Test func keepsChannelsSeparateAndTrimsOldestLines() {
        var timeline = TranscriptTimeline(maximumSegments: 2)
        timeline.apply(event(a, "one", final: true), at: .now)
        timeline.apply(event(b, "two", final: true), at: .now)
        timeline.apply(event(a, "three", final: true), at: .now)

        #expect(timeline.segments.map(\.text) == ["two", "three"])
        #expect(timeline.segments(for: a).map(\.text) == ["three"])
    }
}

@Suite("Transcript writer")
struct TranscriptWriterTests {
    @Test func appendsOneLinePerSegment() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "writer-\(UUID().uuidString)/Session.jsonl")
        let writer = TranscriptWriter(url: url)
        let channel = UUID()

        try writer.append(TranscriptSegment(channelID: channel, text: "Standby", timestamp: .now, sessionOffset: 1, isFinal: true))
        try writer.append(TranscriptSegment(channelID: channel, text: "Go", timestamp: .now, sessionOffset: 2, isFinal: true))

        let segments = TranscriptFile.segments(in: try Data(contentsOf: url))
        #expect(segments.map(\.text) == ["Standby", "Go"])
    }
}
