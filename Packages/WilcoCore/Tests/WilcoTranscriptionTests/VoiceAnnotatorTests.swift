import FluidAudio
import CoreMedia
import Foundation
import Speech
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

    /// One print per half second, each for the voice its first sample names.
    final class WindowedVoiceprints: VoiceprintExtractor {
        func prepare() async throws {}
        func voiceprints(of samples: [Float], startingAt offset: Double) async throws -> [Voiceprint] {
            stride(from: 0, to: samples.count, by: 8_000).map { i in
                var vector = [Float](repeating: 0, count: 4)
                vector[min(max(Int(samples[i]), 0), 3)] = 1
                let start = offset + Double(i) / 16_000
                return Voiceprint(vector: vector, start: start, end: min(start + 0.5, offset + Double(samples.count) / 16_000))
            }
        }
    }

    @Test func lineWithTwoVoicesComesBackAsTwoPiecesOfOneLine() async {
        let annotator = VoiceAnnotator(settings: .standard, extractor: WindowedVoiceprints())
        let recognised = line("Standby LX 42 Standing by", at: 10)
        // Voice 1 for 1.5 s, then voice 2 for 1.5 s.
        let audio = [Float](repeating: 1, count: 24_000) + [Float](repeating: 2, count: 24_000)
        let words = [
            TimedWord(text: "Standby", start: 10.0, end: 10.5),
            TimedWord(text: "LX", start: 10.5, end: 10.8),
            TimedWord(text: "42", start: 10.8, end: 11.2),
            TimedWord(text: "Standing", start: 11.6, end: 12.0),
            TimedWord(text: "by", start: 12.0, end: 12.3),
        ]
        let events = await annotator.annotate(recognised, audio: audio, lineStart: 10, lineEnd: 13, words: words)

        #expect(events.map(\.text) == ["Standby LX 42", "Standing by"])
        #expect(events.map(\.stage) == [.annotated(voice: "A", exchange: 1), .annotated(voice: "B", exchange: 1)])
        #expect(events.allSatisfy { $0.lineID == recognised.lineID && $0.isFinal })
        #expect(events.map(\.sessionOffset) == [10, 11.6])
    }

    @Test func lineWithTwoVoicesButNoWordsStaysWhole() async {
        let annotator = VoiceAnnotator(settings: .standard, extractor: WindowedVoiceprints())
        let recognised = line("Standby LX 42 Standing by", at: 10)
        let audio = [Float](repeating: 1, count: 16_000) + [Float](repeating: 2, count: 32_000)
        let events = await annotator.annotate(recognised, audio: audio, lineStart: 10, lineEnd: 13)
        #expect(events.map(\.text) == ["Standby LX 42 Standing by"])
        // The whole line is one voice: the first letter, and only one voice
        // made, so the next new speaker is B.
        #expect(events.map(\.stage) == [.annotated(voice: "A", exchange: 1)])
        let next = await annotator.annotate(
            line("Go", at: 15), audio: [Float](repeating: 3, count: 32_000), lineStart: 15, lineEnd: 17
        )
        #expect(next.map(\.stage) == [.annotated(voice: "B", exchange: 1)])
    }

    @Test func wordsTheTextDoesNotHoldKeepTheLineOneVoice() async {
        // Timings for different text (a rescore that changed it): the line
        // can't be cut, so its two voices' prints make one voice.
        let annotator = VoiceAnnotator(settings: .standard, extractor: WindowedVoiceprints())
        let audio = [Float](repeating: 1, count: 24_000) + [Float](repeating: 2, count: 24_000)
        let stale = [TimedWord(text: "kineses", start: 10, end: 11), TimedWord(text: "rig", start: 11.6, end: 12.3)]
        let events = await annotator.annotate(
            line("Kinesys standing by", at: 10), audio: audio, lineStart: 10, lineEnd: 13, words: stale
        )
        #expect(events.map(\.stage) == [.annotated(voice: "A", exchange: 1)])
        let next = await annotator.annotate(
            line("Go", at: 15), audio: [Float](repeating: 3, count: 32_000), lineStart: 15, lineEnd: 17
        )
        #expect(next.map(\.stage) == [.annotated(voice: "B", exchange: 1)])
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

    /// A model that can be installed and removed while the annotator runs.
    final class FlakyVoiceprints: VoiceprintExtractor {
        let installed = Mutex(false)
        let prepares = Mutex(0)
        func prepare() async throws {
            prepares.withLock { $0 += 1 }
            if !installed.withLock({ $0 }) { throw VoiceprintError.notInstalled }
        }
        func voiceprints(of samples: [Float], startingAt offset: Double) async throws -> [Voiceprint] {
            if !installed.withLock({ $0 }) { throw VoiceprintError.notInstalled }
            var vector = [Float](repeating: 0, count: 4)
            vector[min(max(Int(samples.first ?? 0), 0), 3)] = 1
            return [Voiceprint(vector: vector, start: offset, end: offset + Double(samples.count) / 16_000)]
        }
    }

    private func stage(_ annotator: VoiceAnnotator, _ at: Double) async -> LineStage? {
        await annotator.annotate(line("x", at: at), audio: audio(1), lineStart: at, lineEnd: at + 2).first?.stage
    }

    @Test func modelInstalledMidRunGivesLettersAfterTheRetryInterval() async {
        let extractor = FlakyVoiceprints()
        let clock = Mutex(100.0)
        let annotator = VoiceAnnotator(settings: .standard, extractor: extractor, now: { clock.withLock { $0 } })
        await annotator.prepare()
        #expect(await stage(annotator, 0) == .annotated(voice: nil, exchange: 1))

        extractor.installed.withLock { $0 = true }
        clock.withLock { $0 += 1 }
        #expect(await stage(annotator, 3) == .annotated(voice: nil, exchange: 1))
        clock.withLock { $0 += VoiceAnnotator.retryInterval }
        #expect(await stage(annotator, 6) == .annotated(voice: "A", exchange: 1))
    }

    @Test func usableFollowsWhetherTheModelLoads() async {
        let extractor = FlakyVoiceprints()
        let clock = Mutex(0.0)
        let annotator = VoiceAnnotator(settings: .standard, extractor: extractor, now: { clock.withLock { $0 } })
        await annotator.prepare()
        #expect(!annotator.isUsable, "transcribers skip word times and audio history")

        extractor.installed.withLock { $0 = true }
        clock.withLock { $0 += VoiceAnnotator.retryInterval }
        _ = await stage(annotator, 0)
        #expect(annotator.isUsable, "a model installed mid-run is picked up")

        extractor.installed.withLock { $0 = false }
        _ = await stage(annotator, 3)
        #expect(!annotator.isUsable, "a model removed mid-run is let go")
    }

    @Test func missingModelIsRetriedOncePerIntervalWhateverTheLineRate() async {
        let extractor = FlakyVoiceprints()
        let clock = Mutex(0.0)
        let annotator = VoiceAnnotator(settings: .standard, extractor: extractor, now: { clock.withLock { $0 } })
        await annotator.prepare()
        for i in 0..<20 {
            clock.withLock { $0 += 0.2 }
            _ = await stage(annotator, Double(i))
        }
        #expect(extractor.prepares.withLock { $0 } == 1)
        clock.withLock { $0 += VoiceAnnotator.retryInterval }
        _ = await stage(annotator, 30)
        _ = await stage(annotator, 31)
        #expect(extractor.prepares.withLock { $0 } == 2)
    }

    @Test func modelRemovedMidRunFallsBackThenRecoversAfterReinstall() async {
        let extractor = FlakyVoiceprints()
        extractor.installed.withLock { $0 = true }
        let clock = Mutex(0.0)
        let annotator = VoiceAnnotator(settings: .standard, extractor: extractor, now: { clock.withLock { $0 } })
        await annotator.prepare()
        #expect(await stage(annotator, 0) == .annotated(voice: "A", exchange: 1))

        extractor.installed.withLock { $0 = false }
        #expect(await stage(annotator, 3) == .annotated(voice: nil, exchange: 1))
        let before = extractor.prepares.withLock { $0 }
        #expect(await stage(annotator, 6) == .annotated(voice: nil, exchange: 1))
        #expect(extractor.prepares.withLock { $0 } == before)

        extractor.installed.withLock { $0 = true }
        clock.withLock { $0 += VoiceAnnotator.retryInterval }
        #expect(await stage(annotator, 9) == .annotated(voice: "A", exchange: 1))
    }

    /// A steady clock tests move by hand.
    final class TestClock: Sendable {
        let time = Mutex(0.0)
        func now() -> Double { time.withLock { $0 } }
        func advance(_ seconds: Double) { time.withLock { $0 += seconds } }
    }

    /// A model whose load takes `loadTime` seconds on `clock` and then fails.
    final class SlowFailingVoiceprints: VoiceprintExtractor {
        let clock: TestClock
        let loadTime: Double
        let prepares = Mutex(0)
        init(clock: TestClock, loadTime: Double) {
            self.clock = clock
            self.loadTime = loadTime
        }
        func prepare() async throws {
            prepares.withLock { $0 += 1 }
            clock.advance(loadTime)
            throw VoiceprintError.notInstalled
        }
        func voiceprints(of samples: [Float], startingAt offset: Double) async throws -> [Voiceprint] {
            throw VoiceprintError.notInstalled
        }
    }

    @Test func slowFailingLoadWaitsTheFullIntervalAfterItEnds() async {
        let clock = TestClock()
        let extractor = SlowFailingVoiceprints(clock: clock, loadTime: 10)
        let annotator = VoiceAnnotator(settings: .standard, extractor: extractor, now: clock.now)
        await annotator.prepare()
        // The load ended at 10 s; 3 s later is too soon to try again.
        clock.advance(3)
        _ = await stage(annotator, 0)
        #expect(extractor.prepares.withLock { $0 } == 1)
        // A full interval after the failed load ended, it is tried again.
        clock.advance(VoiceAnnotator.retryInterval - 3)
        _ = await stage(annotator, 5)
        #expect(extractor.prepares.withLock { $0 } == 2)
    }

    @Test func newSettingsApplyFromTheNextLineAndKeepTheExchange() async {
        let annotator = VoiceAnnotator(settings: .standard, extractor: FakeVoiceprints())
        _ = await annotator.annotate(line("one", at: 0), audio: audio(1), lineStart: 0, lineEnd: 2)
        _ = await annotator.annotate(line("two", at: 3), audio: audio(2), lineStart: 3, lineEnd: 5)

        // A shorter exchange gap: the exchange so far and its letters are kept…
        await annotator.update(settings: VoiceChangeSettings(exchangeGap: 5))
        let kept = await annotator.annotate(line("three", at: 9), audio: audio(2), lineStart: 9, lineEnd: 11)
        #expect(kept.first?.stage == .annotated(voice: "B", exchange: 1))
        // …and a 6 s pause, inside the old 20 s gap, now starts a new one.
        let next = await annotator.annotate(line("four", at: 17), audio: audio(2), lineStart: 17, lineEnd: 19)
        #expect(next.first?.stage == .annotated(voice: "A", exchange: 2))
    }

    @Test func pendingLinesCoverEveryChannelsFullVoiceQueue() {
        // 32 channels, each with a full queue plus the line being recognised.
        #expect(PendingLines().maximumLines >= 32 * (VoiceAnnotationQueue.maximumPending + 1))
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

    // MARK: - Splitting with real engines

    /// A call and its answer with no pause between them, in two voices,
    /// through `engine` with voice changes on. Returns the annotated pieces.
    private func twoVoicesWithoutAPause(_ engine: SpeechEngine) async throws -> [TranscriptionEvent] {
        var parakeet = ParakeetModelStore()
        if engine == .parakeet, !parakeet.isInstalled() {
            parakeet = ParakeetModelStore(directory: AsrModels.defaultCacheDirectory(for: .v3).deletingLastPathComponent())
            if !parakeet.isInstalled() { try await parakeet.install { _ in } }
        }
        let voices = WeSpeakerVoiceprints()
        if !voices.isInstalled() { try await voices.install { _ in } }

        var show = ShowDocument()
        var channel = show.addChannel(engine: engine)
        channel.detectsVoiceChanges = true
        channel.localeIdentifier = "en_US"
        let log = Log()
        let ring = AudioRingBuffer(capacity: 16_000 * 60)
        let transcriber = ChannelTranscribers.make(
            configuration: TranscriberConfiguration(channel: channel, show: show),
            source: AudioSource(ring: ring, sampleRate: { 16_000 }), sessionOffset: 0,
            whisperModels: WhisperModelStore(), parakeetModels: parakeet, voiceprints: voices,
            onEvent: { event in log.events.withLock { $0.append(event) } }, onStatus: { _ in }
        )
        await transcriber.start()
        let audio = try sayClip("Standby lighting cue forty two and sound cue seventeen", voice: sayVoice("Samantha"))
            + sayClip("Lighting is standing by for cue forty two", voice: sayVoice("Daniel"))
            + [Float](repeating: 0, count: 16_000 * 2)
        for chunk in stride(from: 0, to: audio.count, by: 1_600) {
            ring.write(Array(audio[chunk..<min(chunk + 1_600, audio.count)]))
            try await Task.sleep(for: .milliseconds(100))
        }
        try await Task.sleep(for: .seconds(2))
        await transcriber.stop()

        let events = log.events.withLock { $0 }
        for event in events where event.isFinal {
            print("\(engine) \(event.stage) @\(String(format: "%.2f", event.sessionOffset)) line \(event.lineID.uuidString.prefix(4)): \(event.text)")
        }
        return events.filter { if case .annotated = $0.stage { true } else { false } }
    }

    private func letters(_ pieces: [TranscriptionEvent]) -> [String?] {
        pieces.map { if case .annotated(let voice, _) = $0.stage { voice } else { nil } }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["WILCO_ASR_TESTS"] != nil), .timeLimit(.minutes(5)))
    func parakeetSplitsAnAnswerWithNoPause() async throws {
        let pieces = try await twoVoicesWithoutAPause(.parakeet)
        #expect(letters(pieces) == ["A", "B"])
        // One utterance, cut in two by voice.
        #expect(Set(pieces.map(\.lineID)).count == 1)
        #expect(pieces.last?.text.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("lighting") == true)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["WILCO_ASR_TESTS"] != nil), .timeLimit(.minutes(5)))
    func whisperSplitsAnAnswerWithNoPause() async throws {
        try #require(WhisperModelStore().isDownloaded(.base), "Whisper base model is not downloaded")
        let pieces = try await twoVoicesWithoutAPause(.whisper)
        #expect(letters(pieces) == ["A", "B"])
        #expect(Set(pieces.map(\.lineID)).count == 1)
        #expect(pieces.last?.text.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("lighting") == true)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["WILCO_ASR_TESTS"] != nil), .timeLimit(.minutes(5)))
    func appleLongFormGivesAnAnswerWithNoPauseItsOwnLetter() async throws {
        guard #available(macOS 26, *) else { return }
        // Apple may finalise the answer as a line of its own or as part of
        // the call's line; either way it must get its own letter.
        let pieces = try await twoVoicesWithoutAPause(.longForm)
        #expect(letters(pieces) == ["A", "B"])
        #expect(pieces.last?.text.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("lighting") == true)
    }
}

@Suite("Apple word times")
struct AppleWordTimesTests {
    @available(macOS 26, *)
    private func run(_ text: String, _ start: Double, _ duration: Double) -> AttributedString {
        var run = AttributedString(text)
        run[AttributeScopes.SpeechAttributes.TimeRangeAttribute.self] = CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 1_000),
            duration: CMTime(seconds: duration, preferredTimescale: 1_000)
        )
        return run
    }

    @available(macOS 26, *)
    @Test func runsWithTimeRangesBecomeWordsInSessionTime() {
        var text = run("Standby", 1.0, 0.5)
        text += AttributedString(" ")
        text += run("LX", 1.5, 0.25)
        // A word split over two runs (different confidences) keeps one range.
        var by = run("4", 1.75, 0.5)
        by[AttributeScopes.SpeechAttributes.ConfidenceAttribute.self] = 0.9
        text += by
        text += run("2", 1.75, 0.5)
        let words = AppleChannelTranscriber.words(in: text, sessionOffset: 100)
        #expect(words.map(\.text) == ["Standby", "LX", "42"])
        #expect(words.map(\.start) == [101.0, 101.5, 101.75])
        #expect(words.map(\.end) == [101.5, 101.75, 102.25])
    }

    @available(macOS 26, *)
    @Test func textWithoutTimesGivesNoWords() {
        #expect(AppleChannelTranscriber.words(in: AttributedString("Standby LX 42"), sessionOffset: 0).isEmpty)
    }
}
