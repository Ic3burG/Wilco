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

    /// Talking as a mic in a room hears it: echoes fill the dips between
    /// syllables, so they only fall to about a third of the speech level.
    private func roomSyllables(_ seconds: Double, amplitude: Float = 0.3) -> [Float] {
        let on = Int(0.2 * rate), period = Int(0.28 * rate)
        return (0..<Int(seconds * rate)).map { i in
            (i % period < on ? amplitude : amplitude * 0.35) * sin(Float(i) * 2 * .pi * 440 / Float(rate))
        }
    }

    private func hiss(_ seconds: Double, amplitude: Float = 0.002) -> [Float] {
        var generator = SystemRandomNumberGenerator()
        return (0..<Int(seconds * rate)).map { _ in Float.random(in: -amplitude...amplitude, using: &generator) }
    }

    private func mixed(_ a: [Float], _ b: [Float]) -> [Float] { zip(a, b).map(+) }

    /// The dips in room speech are not background: learning them as the
    /// noise floor would put the speech itself under the threshold and end
    /// the utterance mid-sentence.
    @Test func continuousRoomSpeechIsNotLearnedAsBackground() throws {
        var segmenter = UtteranceSegmenter(sampleRate: rate)
        var utterances = segmenter.append(roomSyllables(10) + silence(1))
        if let last = segmenter.flush() { utterances.append(last) }
        #expect(utterances.count == 1)
        let seconds = Double(try #require(utterances.first).samples.count) / rate
        #expect(seconds >= 10, "cut after \(seconds) s of 10 s of talking")
    }

    /// Between utterances, sound too quiet to count as speech must not drag
    /// the floor up to its own level unless it is steady, or the speaker has
    /// to get much louder before anything is heard again.
    @Test func quietMutteringDoesNotRaiseTheFloor() {
        var segmenter = UtteranceSegmenter(sampleRate: rate)
        let muttering = mixed(roomSyllables(5, amplitude: 0.006), hiss(5))
        let talking = mixed(roomSyllables(3, amplitude: 0.012), hiss(3))
        var utterances = segmenter.append(hiss(2) + muttering)
        #expect(utterances.isEmpty)
        utterances = segmenter.append(talking + hiss(1))
        if let last = segmenter.flush() { utterances.append(last) }
        let kept = Double(utterances.reduce(0) { $0 + $1.samples.count }) / rate
        #expect(kept >= 2.7, "only \(kept) s of 3 s of talking came through")
    }

    @Test func flushReturnsSpeechInProgress() {
        var segmenter = UtteranceSegmenter(sampleRate: rate)
        _ = segmenter.append(tone(1))
        #expect(segmenter.flush() != nil)
        #expect(segmenter.flush() == nil)
    }

    @Test func inProgressIsNilInSilence() {
        var segmenter = UtteranceSegmenter(sampleRate: rate)
        _ = segmenter.append(silence(1))
        #expect(segmenter.inProgress == nil)
    }

    @Test func inProgressGrowsDuringSpeechAndClearsAfterTheCut() throws {
        var segmenter = UtteranceSegmenter(sampleRate: rate)
        _ = segmenter.append(silence(1) + syllables(0.5))
        let early = try #require(segmenter.inProgress)
        _ = segmenter.append(syllables(0.5))
        let later = try #require(segmenter.inProgress)
        #expect(later.samples.count > early.samples.count)
        #expect(later.startOffset == early.startOffset)
        // One second of silence less the pre-roll.
        #expect(abs(early.startOffset - (1 - segmenter.preRoll)) < 0.03)
        let finished = segmenter.append(silence(1))
        #expect(finished.count == 1)
        #expect(segmenter.inProgress == nil)
    }

    @Test func countsSpeechAndThePauseInProgress() {
        var segmenter = UtteranceSegmenter(sampleRate: rate)
        #expect(segmenter.speechInProgress == 0)
        _ = segmenter.append(silence(1) + tone(0.6))
        #expect(abs(segmenter.speechInProgress - 0.6) < 0.05)
        #expect(segmenter.silenceInProgress == 0)
        _ = segmenter.append(silence(0.4))
        #expect(abs(segmenter.silenceInProgress - 0.4) < 0.05)
        _ = segmenter.append(silence(1))
        #expect(segmenter.speechInProgress == 0)
        #expect(segmenter.silenceInProgress == 0)
    }

    @Test func inProgressRestartsAfterAMaximumLengthCut() throws {
        var segmenter = UtteranceSegmenter(sampleRate: rate)
        segmenter.maximumLength = 2
        let cut = segmenter.append(syllables(2.5))
        #expect(cut.count == 1)
        let next = try #require(segmenter.inProgress)
        #expect(next.startOffset >= 1.99)
        #expect(Double(next.samples.count) / rate < 0.6)
    }
}

@Suite("Recogniser vocabulary")
struct VocabularyTests {
    @Test func mergesShowVocabularyAndRulePhrasesWithoutDuplicates() {
        var show = ShowDocument()
        let channel = show.addChannel()
        let other = show.addChannel()
        show.globalVocabulary = ["Standby", "Pyro", "Omar", "pyro"]
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

    /// A quiet channel reporting a lone "." left an empty row at the live end.
    @Test func punctuationOnlyWordsInProgressAreHidden() {
        var timeline = TranscriptTimeline()
        timeline.apply(event(a, ".", final: false), at: .now)
        timeline.apply(event(b, " … ", final: false), at: .now)
        #expect(timeline.volatile.isEmpty)

        timeline.apply(event(a, "Go 12.", final: false), at: .now)
        #expect(timeline.volatile[a] == "Go 12.")
        timeline.apply(event(a, ".", final: false), at: .now)
        #expect(timeline.volatile[a] == nil)

        let recognized = TranscriptionEvent(channelID: b, text: ".", isFinal: true, sessionOffset: 0,
                                            confidence: nil, stage: .recognized)
        timeline.apply(recognized, at: .now)
        #expect(timeline.volatile[b] == nil)
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

    @Test func recognizedLineShowsAsInProgressUntilAnnotated() {
        var timeline = TranscriptTimeline()
        let id = UUID(), channel = UUID()
        #expect(timeline.apply(.init(channelID: channel, text: "Standby LX 42", isFinal: true, sessionOffset: 5, confidence: nil, lineID: id, stage: .recognized), at: .now) == nil)
        #expect(timeline.volatile[channel] == "Standby LX 42")
        let first = timeline.apply(.init(channelID: channel, text: "Standby LX 42", isFinal: true, sessionOffset: 5, confidence: nil, lineID: id, stage: .annotated(voice: "A", exchange: 1)), at: .now)
        #expect(first?.voice == "A" && timeline.volatile[channel] == nil)
    }

    @Test func annotatedPiecesBecomeSeparateLinesWithTheirVoice() {
        var timeline = TranscriptTimeline()
        let id = UUID()
        timeline.apply(.init(channelID: a, text: "Standby LX 42", isFinal: true, sessionOffset: 5, confidence: nil, lineID: id, stage: .recognized), at: .now)
        timeline.apply(.init(channelID: a, text: "Standby", isFinal: true, sessionOffset: 5, confidence: nil, lineID: id, stage: .annotated(voice: "A", exchange: 2)), at: .now)
        timeline.apply(.init(channelID: a, text: "LX 42", isFinal: true, sessionOffset: 6, confidence: nil, lineID: id, stage: .annotated(voice: "B", exchange: 2)), at: .now)
        #expect(timeline.segments.map(\.text) == ["Standby", "LX 42"])
        #expect(timeline.segments.map(\.voice) == ["A", "B"])
        #expect(timeline.segments.map(\.exchange) == [2, 2])
    }

    @Test func annotationKeepsNewerWordsInProgress() {
        // The next call's words may arrive before voice analysis finishes the
        // previous line; the annotation must not wipe them.
        var timeline = TranscriptTimeline()
        let id = UUID()
        timeline.apply(.init(channelID: a, text: "Standby LX 42", isFinal: true, sessionOffset: 5, confidence: nil, lineID: id, stage: .recognized), at: .now)
        timeline.apply(event(a, "LX 42", final: false, at: 8), at: .now)
        timeline.apply(.init(channelID: a, text: "Standby LX 42", isFinal: true, sessionOffset: 5, confidence: nil, lineID: id, stage: .annotated(voice: nil, exchange: nil)), at: .now)
        #expect(timeline.volatile[a] == "LX 42")
        #expect(timeline.segments.map(\.text) == ["Standby LX 42"])
    }

    @Test func aRecognizedLineWithNoAnnotationIsReplacedByTheNextLine() {
        var timeline = TranscriptTimeline()
        timeline.apply(.init(channelID: a, text: "Standby LX 42", isFinal: true, sessionOffset: 5, confidence: nil, stage: .recognized), at: .now)
        timeline.apply(event(a, "Go", final: true, at: 9), at: .now)
        #expect(timeline.volatile[a] == nil)
        #expect(timeline.segments.map(\.text) == ["Go"])
    }

    private func staged(_ channel: UUID, _ text: String, _ id: UUID, _ stage: LineStage) -> TranscriptionEvent {
        .init(channelID: channel, text: text, isFinal: true, sessionOffset: 5, confidence: nil, lineID: id, stage: stage)
    }

    @Test func clearingAChannelDropsLateAnnotationsOfItsEarlierLines() {
        var timeline = TranscriptTimeline()
        let early = UUID(), other = UUID(), later = UUID()
        timeline.apply(staged(a, "Standby LX 42", early, .recognized), at: .now)
        timeline.apply(staged(b, "LX standing by", other, .recognized), at: .now)
        timeline.clear(channelID: a)

        // Voice analysis for the cleared line finishes after the clear: it
        // still goes to the session file, but doesn't come back on screen.
        let late = timeline.apply(staged(a, "Standby LX 42", early, .annotated(voice: "A", exchange: 1)), at: .now)
        #expect(late?.text == "Standby LX 42")
        #expect(timeline.segments(for: a).isEmpty)

        // Another channel's line, and a line heard after the clear, still show.
        timeline.apply(staged(b, "LX standing by", other, .annotated(voice: "A", exchange: 1)), at: .now)
        timeline.apply(staged(a, "Go", later, .recognized), at: .now)
        timeline.apply(staged(a, "Go", later, .annotated(voice: "B", exchange: 1)), at: .now)
        #expect(timeline.segments.map(\.text) == ["LX standing by", "Go"])
    }

    @Test func clearingEverythingDropsLateAnnotationsOfEveryChannel() {
        var timeline = TranscriptTimeline()
        let first = UUID(), second = UUID()
        timeline.apply(staged(a, "one", first, .recognized), at: .now)
        timeline.apply(staged(b, "two", second, .recognized), at: .now)
        timeline.clear()
        timeline.apply(staged(a, "one", first, .annotated(voice: "A", exchange: 1)), at: .now)
        timeline.apply(staged(b, "two", second, .annotated(voice: "A", exchange: 1)), at: .now)
        #expect(timeline.segments.isEmpty)
    }

    @Test func completeLinesHaveNoVoice() {
        var timeline = TranscriptTimeline()
        let segment = timeline.apply(event(a, "Standby", final: true), at: .now)
        #expect(segment?.voice == nil && segment?.exchange == nil)
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
