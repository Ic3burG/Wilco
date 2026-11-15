import FluidAudio
import Foundation
import Synchronization
import Testing
import WilcoCore
@testable import WilcoTranscription

@Suite("Voice annotator")
struct VoiceAnnotatorTests {
    /// Gives one print per call, for the voice the audio's first sample names
    /// (1 is one voice, 2 another). Can be slowed per call, or made to fail.
    final class FakeVoiceprints: VoiceprintExtractor {
        let delays: [Duration]
        let fails: Bool
        let calls = Mutex(0)

        init(delays: [Duration] = [], fails: Bool = false) {
            self.delays = delays
            self.fails = fails
        }

        func prepare() async throws {}

        func voiceprints(of samples: [Float], startingAt offset: Double) async throws -> [Voiceprint] {
            let call = calls.withLock { n in defer { n += 1 }; return n }
            if call < delays.count { try? await Task.sleep(for: delays[call]) }
            if fails { throw VoiceprintError.notInstalled }
            var vector = [Float](repeating: 0, count: 4)
            vector[min(max(Int(samples.first ?? 0), 0), 3)] = 1
            return [Voiceprint(vector: vector, start: offset, end: offset + Double(samples.count) / 16_000)]
        }
    }

    /// Two seconds of audio "spoken" by `voice`.
    private func audio(_ voice: Float) -> [Float] { [Float](repeating: voice, count: 32_000) }

    private func line(_ text: String, at offset: Double) -> TranscriptionEvent {
        TranscriptionEvent(
            channelID: UUID(), text: text, isFinal: true, sessionOffset: offset, confidence: 0.8, stage: .recognized
        )
    }

    @Test func annotatorGivesEveryLineALetterAndKeepsItsID() async {
        let annotator = VoiceAnnotator(settings: .standard, extractor: FakeVoiceprints())
        let first = line("Standby LX 42", at: 10)
        let second = line("LX standing by", at: 13)
        let a = await annotator.annotate(first, audio: audio(1), lineStart: 10, lineEnd: 12)
        let b = await annotator.annotate(second, audio: audio(2), lineStart: 13, lineEnd: 15)

        #expect(a.count == 1 && b.count == 1)
        #expect(a.first?.stage == .annotated(voice: "A", exchange: 1))
        #expect(b.first?.stage == .annotated(voice: "B", exchange: 1))
        #expect(a.first?.lineID == first.lineID)
        #expect(b.first?.lineID == second.lineID)
        #expect(a.first?.text == "Standby LX 42")
        #expect(a.first?.channelID == first.channelID)
        #expect(a.first?.sessionOffset == 10)
        #expect(a.first?.confidence == 0.8)
        #expect(a.first?.isFinal == true)
    }

    @Test func failingExtractorStillDeliversTheLine() async {
        let annotator = VoiceAnnotator(settings: .standard, extractor: FakeVoiceprints(fails: true))
        let recognised = line("Go", at: 5)
        let events = await annotator.annotate(recognised, audio: audio(1), lineStart: 5, lineEnd: 7)
        #expect(events.count == 1)
        #expect(events.first?.stage == .annotated(voice: nil, exchange: 1))
        #expect(events.first?.text == "Go")
        #expect(events.first?.lineID == recognised.lineID)
    }

    @Test func restartedChannelStartsAFreshExchange() async {
        let before = VoiceAnnotator(settings: .standard, extractor: FakeVoiceprints())
        _ = await before.annotate(line("one", at: 0), audio: audio(1), lineStart: 0, lineEnd: 2)
        let b = await before.annotate(line("two", at: 3), audio: audio(2), lineStart: 3, lineEnd: 5)
        #expect(b.first?.stage == .annotated(voice: "B", exchange: 1))

        // The channel restarts: a new annotator knows no voices.
        let after = VoiceAnnotator(settings: .standard, extractor: FakeVoiceprints())
        let again = await after.annotate(line("three", at: 6), audio: audio(2), lineStart: 6, lineEnd: 8)
        #expect(again.first?.stage == .annotated(voice: "A", exchange: 1))
    }

    @Test(.timeLimit(.minutes(1))) func annotationsArriveInLineOrderEvenWhenTheFirstIsSlow() async {
        // The first line's prints take half a second, the second's none: if
        // annotations ran side by side, the second would arrive first.
        let log = Log()
        let queue = VoiceAnnotationQueue(
            annotator: VoiceAnnotator(settings: .standard, extractor: FakeVoiceprints(delays: [.milliseconds(500)])),
            onEvent: { event in log.events.withLock { $0.append(event) } }
        )
        let first = line("first", at: 0)
        let second = line("second", at: 3)
        queue.submit(first, audio: { audio(1) }, lineStart: 0, lineEnd: 2)
        queue.submit(second, audio: { audio(2) }, lineStart: 3, lineEnd: 5)
        await queue.finish()
        #expect(log.events.withLock { $0 }.map(\.lineID) == [first.lineID, second.lineID])
    }

    @Test(.timeLimit(.minutes(1))) func fullQueueStillAnnotatesEveryLineInOrderWithoutItsAudio() async {
        // Analysis takes 100 ms a line; twenty lines arrive at once.
        let cap = VoiceAnnotationQueue.maximumPending
        let extractor = FakeVoiceprints(delays: Array(repeating: .milliseconds(100), count: 40))
        let log = Log()
        let queue = VoiceAnnotationQueue(
            annotator: VoiceAnnotator(settings: .standard, extractor: extractor),
            onEvent: { event in log.events.withLock { $0.append(event) } }
        )
        let lines = (0..<20).map { line("line \($0)", at: Double($0) * 3) }
        let fetched = Mutex(0)
        for (i, recognised) in lines.enumerated() {
            queue.submit(
                recognised, audio: { fetched.withLock { $0 += 1 }; return audio(1) },
                lineStart: Double(i) * 3, lineEnd: Double(i) * 3 + 2
            )
        }
        await queue.finish()

        // Never more than the cap's worth of audio held or fetched.
        #expect(queue.mostPending <= cap)
        #expect(fetched.withLock { $0 } == cap)
        #expect(extractor.calls.withLock { $0 } == cap)
        // Every line annotated exactly once, in order.
        let events = log.events.withLock { $0 }
        #expect(events.map(\.lineID) == lines.map(\.lineID))
        // The admitted lines get the voice; the overflow ones none, in the same exchange.
        #expect(events.prefix(cap).allSatisfy { $0.stage == .annotated(voice: "A", exchange: 1) })
        #expect(events.dropFirst(cap).allSatisfy { $0.stage == .annotated(voice: nil, exchange: 1) })
    }

    // MARK: - Through a transcriber

    /// Numbers its lines: "line 1", "line 2"…
    final class CountingRecognizer: UtteranceRecognizer {
        let count = Mutex(0)
        func prepare() async throws {}
        func recognize(_ samples: [Float]) async throws -> Recognition? {
            let n = count.withLock { $0 += 1; return $0 }
            return Recognition(text: "line \(n)", confidence: nil)
        }
    }

    final class Log: Sendable {
        let events = Mutex<[TranscriptionEvent]>([])
    }

    private static let rate = 48_000.0

    private func speech(seconds: Double) -> [Float] {
        (0..<Int(seconds * Self.rate)).map { Float(sin(Double($0) * 2 * .pi * 440 / Self.rate)) * 0.3 }
    }

    private func silence(seconds: Double) -> [Float] { [Float](repeating: 0, count: Int(seconds * Self.rate)) }

    private func transcriber(
        voiceChanges: VoiceChangeSettings?, extractor: (any VoiceprintExtractor)?, log: Log
    ) -> (UtteranceChannelTranscriber, AudioRingBuffer) {
        let ring = AudioRingBuffer(capacity: Int(Self.rate) * 20)
        let transcriber = UtteranceChannelTranscriber(
            channelID: UUID(), source: AudioSource(ring: ring, sampleRate: { Self.rate }), sessionOffset: 0,
            recognizer: CountingRecognizer(), voiceChanges: voiceChanges, voiceprints: extractor,
            onEvent: { event in log.events.withLock { $0.append(event) } }, onStatus: { _ in }
        )
        return (transcriber, ring)
    }

    private func waitFor(_ log: Log, _ condition: ([TranscriptionEvent]) -> Bool) async throws {
        for _ in 0..<100 where !condition(log.events.withLock({ $0 })) {
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    @Test(.timeLimit(.minutes(1))) func voiceChangesOffEmitsCompleteOnly() async throws {
        let log = Log()
        let (transcriber, ring) = transcriber(voiceChanges: nil, extractor: FakeVoiceprints(), log: log)
        await transcriber.start()
        ring.write(speech(seconds: 1) + silence(seconds: 1.5) + speech(seconds: 1) + silence(seconds: 1.5))
        try await waitFor(log) { $0.count >= 2 }
        await transcriber.stop()
        let events = log.events.withLock { $0 }
        #expect(events.map(\.text) == ["line 1", "line 2"])
        #expect(events.allSatisfy { $0.stage == .complete })
    }

    @Test(.timeLimit(.minutes(1))) func slowVoiceAnalysisDoesNotHoldUpTheNextLine() async throws {
        let log = Log()
        let (transcriber, ring) = transcriber(
            voiceChanges: .standard, extractor: FakeVoiceprints(delays: [.seconds(2)]), log: log
        )
        await transcriber.start()
        ring.write(speech(seconds: 1) + silence(seconds: 1.5) + speech(seconds: 1) + silence(seconds: 1.5))
        try await waitFor(log) { $0.count >= 4 }
        await transcriber.stop()

        let events = log.events.withLock { $0 }
        try #require(events.count == 4)
        // Both lines reach rules while the first is still being analysed, and
        // the annotations follow in line order.
        #expect(events.map(\.text) == ["line 1", "line 2", "line 1", "line 2"])
        #expect(events[0].stage == .recognized && events[1].stage == .recognized)
        #expect(events[2].lineID == events[0].lineID)
        #expect(events[3].lineID == events[1].lineID)
        guard case .annotated = events[2].stage, case .annotated = events[3].stage else {
            Issue.record("expected annotations, got \(events.map(\.stage))")
            return
        }
    }

    @Test(.timeLimit(.minutes(1))) func stopDeliversAPendingAnnotation() async throws {
        let log = Log()
        let (transcriber, ring) = transcriber(
            voiceChanges: .standard, extractor: FakeVoiceprints(delays: [.seconds(1)]), log: log
        )
        await transcriber.start()
        ring.write(speech(seconds: 1) + silence(seconds: 1.5))
        try await waitFor(log) { !$0.isEmpty }
        #expect(log.events.withLock { $0 }.map(\.stage) == [.recognized])
        await transcriber.stop()

        let events = log.events.withLock { $0 }
        try #require(events.count == 2)
        #expect(events[1].lineID == events[0].lineID)
        #expect(events[1].stage == .annotated(voice: "A", exchange: 1))
    }

    @Test(.timeLimit(.minutes(1))) func missingVoiceModelStillDeliversLines() async throws {
        let log = Log()
        // Voice changes on, but no extractor at all (as the bench passes).
        let (transcriber, ring) = transcriber(voiceChanges: .standard, extractor: nil, log: log)
        await transcriber.start()
        ring.write(speech(seconds: 1) + silence(seconds: 1.5))
        try await waitFor(log) { $0.count >= 2 }
        await transcriber.stop()
        #expect(log.events.withLock { $0 }.map(\.stage) == [.recognized, .annotated(voice: nil, exchange: 1)])
    }

    // MARK: - Real models

    @Test(.enabled(if: ProcessInfo.processInfo.environment["WILCO_ASR_TESTS"] != nil), .timeLimit(.minutes(5)))
    func twoRealVoicesGetTwoLetters() async throws {
        // The app's model when installed, else FluidAudio's cache (same files).
        var parakeet = ParakeetModelStore()
        if !parakeet.isInstalled() {
            parakeet = ParakeetModelStore(directory: AsrModels.defaultCacheDirectory(for: .v3).deletingLastPathComponent())
        }
        if !parakeet.isInstalled() { try await parakeet.install { _ in } }
        let voices = WeSpeakerVoiceprints()
        if !voices.isInstalled() { try await voices.install { _ in } }

        let log = Log()
        let ring = AudioRingBuffer(capacity: 16_000 * 60)
        let transcriber = UtteranceChannelTranscriber(
            channelID: UUID(), source: AudioSource(ring: ring, sampleRate: { 16_000 }), sessionOffset: 0,
            recognizer: ParakeetRecognizer(store: parakeet, language: .english),
            voiceChanges: .standard, voiceprints: voices,
            onEvent: { event in log.events.withLock { $0.append(event) } }, onStatus: { _ in }
        )
        await transcriber.start()
        let gap = [Float](repeating: 0, count: 16_000 * 3 / 2)
        let samantha = try sayVoice("Samantha"), daniel = try sayVoice("Daniel")
        let audio = try sayClip("Standby lighting cue forty two and sound cue seventeen", voice: samantha) + gap
            + sayClip("Lighting is standing by for cue forty two", voice: daniel) + gap
            + sayClip("Lighting cue forty two, go", voice: samantha) + gap
        for chunk in stride(from: 0, to: audio.count, by: 1_600) {
            ring.write(Array(audio[chunk..<min(chunk + 1_600, audio.count)]))
            try await Task.sleep(for: .milliseconds(100))
        }
        try await Task.sleep(for: .seconds(2))
        await transcriber.stop()

        let annotated = log.events.withLock { $0 }.compactMap { event -> String?? in
            guard case .annotated(let voice, _) = event.stage else { return nil }
            print("Voice \(voice ?? "·"): \(event.text)")
            return voice
        }
        #expect(annotated == ["A", "B", "A"])
    }
}
