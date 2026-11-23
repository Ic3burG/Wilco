import Foundation
import Synchronization
import Testing
import WilcoCore
@testable import WilcoTranscription

@Suite("Utterance transcriber")
struct UtteranceTranscriberTests {
    /// Answers every utterance with a fixed line and remembers what it got.
    final class FakeRecognizer: UtteranceRecognizer {
        let heard = Mutex<[Int]>([])
        let prepared = Mutex(0)
        let previews = Mutex(0)
        let failPrepare: Bool
        /// Throws when its task is cancelled, as Parakeet's pipeline does.
        let honoursCancellation: Bool
        /// What a final line says; empty when the model heard nothing.
        let finalText: String
        init(failPrepare: Bool = false, honoursCancellation: Bool = false, finalText: String = " standby go ") {
            self.failPrepare = failPrepare
            self.honoursCancellation = honoursCancellation
            self.finalText = finalText
        }

        func prepare() async throws {
            prepared.withLock { $0 += 1 }
            if failPrepare { throw TranscriberError("no model") }
        }

        func recognize(_ samples: [Float]) async throws -> Recognition? {
            heard.withLock { $0.append(samples.count) }
            if honoursCancellation { try Task.checkCancellation() }
            return Recognition(text: finalText, confidence: 0.9)
        }

        func preview(_ samples: [Float]) async -> Recognition? {
            previews.withLock { $0 += 1 }
            return Recognition(text: " standby ", confidence: nil)
        }
    }

    private final class Log: Sendable {
        let events = Mutex<[TranscriptionEvent]>([])
        let statuses = Mutex<[TranscriberStatus]>([])
    }

    /// A tone loud enough to count as speech.
    private func speech(seconds: Double, rate: Double) -> [Float] {
        (0..<Int(seconds * rate)).map { Float(sin(Double($0) * 2 * .pi * 440 / rate)) * 0.3 }
    }

    @Test(.timeLimit(.minutes(1))) func cutsAtPausesAndSendsFinalLines() async throws {
        let rate = 48_000.0
        let ring = AudioRingBuffer(capacity: Int(rate) * 10)
        let recognizer = FakeRecognizer()
        let log = Log()
        let channel = UUID()
        let transcriber = UtteranceChannelTranscriber(
            channelID: channel, source: AudioSource(ring: ring, sampleRate: { rate }), sessionOffset: 10,
            recognizer: recognizer,
            onEvent: { event in log.events.withLock { $0.append(event) } },
            onStatus: { status in log.statuses.withLock { $0.append(status) } }
        )
        await transcriber.start()
        #expect(log.statuses.withLock { $0 } == [.preparing, .listening])

        // Half a second of silence, one second of speech, then a pause.
        _ = ring.write([Float](repeating: 0, count: Int(rate * 0.5)) + speech(seconds: 1, rate: rate)
            + [Float](repeating: 0, count: Int(rate * 1.5)))
        for _ in 0..<50 where log.events.withLock({ $0.isEmpty }) {
            try await Task.sleep(for: .milliseconds(100))
        }
        await transcriber.stop()

        let events = log.events.withLock { $0 }
        try #require(events.count == 1)
        #expect(events[0].channelID == channel)
        #expect(events[0].text == "standby go")
        #expect(events[0].isFinal)
        #expect(events[0].confidence == 0.9)
        // Starts at the speech (0.5 s) less the pre-roll, after the session offset.
        #expect(abs(events[0].sessionOffset - 10.2) < 0.1, "offset \(events[0].sessionOffset)")
        // The recognizer gets 16 kHz audio: 0.3 s pre-roll, 1 s of speech and
        // the 0.7 s pause that ended it.
        let samples = try #require(recognizer.heard.withLock { $0.first })
        #expect((30_000...34_000).contains(samples), "got \(samples) samples")
    }

    @Test func reportsAModelThatFailsToLoad() async {
        let log = Log()
        let transcriber = UtteranceChannelTranscriber(
            channelID: UUID(), source: AudioSource(ring: AudioRingBuffer(capacity: 1_000), sampleRate: { 48_000 }),
            sessionOffset: 0, recognizer: FakeRecognizer(failPrepare: true),
            onEvent: { _ in }, onStatus: { status in log.statuses.withLock { $0.append(status) } }
        )
        await transcriber.start()
        await transcriber.stop()
        let last = log.statuses.withLock { $0.last }
        guard case .failed(let message) = last else {
            Issue.record("expected a failure, got \(String(describing: last))")
            return
        }
        #expect(message.contains("no model"))
    }

    // MARK: Previews

    /// Speech-like: 200 ms syllables with 80 ms dips, so the segmenter
    /// doesn't learn it as background the way it learns a steady tone.
    private func talk(seconds: Double, rate: Double) -> [Float] {
        let on = Int(0.2 * rate), period = Int(0.28 * rate)
        return (0..<Int(seconds * rate)).map { i in
            i % period < on ? Float(sin(Double(i) * 2 * .pi * 440 / rate)) * 0.3 : 0.002
        }
    }

    private func quiet(seconds: Double, rate: Double) -> [Float] {
        [Float](repeating: 0, count: Int(seconds * rate))
    }

    /// Writes `samples` into `ring` in 100 ms pieces at the speed it would
    /// be heard, so the transcriber sees speech while it's still going.
    private func play(_ samples: [Float], into ring: AudioRingBuffer, rate: Double) async throws {
        let piece = Int(rate * 0.1)
        var start = 0
        while start < samples.count {
            let end = min(samples.count, start + piece)
            _ = ring.write(Array(samples[start..<end]))
            start = end
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    /// Runs a transcriber over `audio` played in real time and returns what
    /// it sent. With `stopEarly` the transcriber stops as soon as the audio
    /// has played; otherwise it waits for `finals` final lines first.
    private func run(
        _ audio: [Float], rate: Double, previewInterval: Duration?, maximumLength: Double = 20,
        finals: Int = 1, stopEarly: Bool = false, recognizer: FakeRecognizer = FakeRecognizer()
    ) async throws -> [TranscriptionEvent] {
        let ring = AudioRingBuffer(capacity: Int(rate) * 30)
        let log = Log()
        let transcriber = UtteranceChannelTranscriber(
            channelID: UUID(), source: AudioSource(ring: ring, sampleRate: { rate }), sessionOffset: 0,
            recognizer: recognizer, previewInterval: previewInterval, maximumUtteranceLength: maximumLength,
            onEvent: { event in log.events.withLock { $0.append(event) } }, onStatus: { _ in }
        )
        await transcriber.start()
        try await play(audio, into: ring, rate: rate)
        if !stopEarly {
            for _ in 0..<50 where log.events.withLock({ $0.filter(\.isFinal).count }) < finals {
                try await Task.sleep(for: .milliseconds(100))
            }
        }
        await transcriber.stop()
        return log.events.withLock { $0 }
    }

    @Test(.timeLimit(.minutes(1))) func meteredChannelReportsUtterances() async throws {
        let rate = 48_000.0
        let ring = AudioRingBuffer(capacity: Int(rate) * 30)
        let channel = UUID()
        let reports = Mutex<[MeterReport]>([])
        // Started 59 s ago, so the first minute closes during the test.
        let tap = DiagnosticsTap(sessionStart: Date(timeIntervalSinceNow: -59)) { report in
            reports.withLock { $0.append(report) }
        }
        let log = Log()
        let transcriber = UtteranceChannelTranscriber(
            channelID: channel, source: AudioSource(ring: ring, sampleRate: { rate }, diagnostics: tap),
            sessionOffset: 0, recognizer: FakeRecognizer(),
            onEvent: { event in log.events.withLock { $0.append(event) } }, onStatus: { _ in }
        )
        await transcriber.start()
        try await play(talk(seconds: 1, rate: rate) + quiet(seconds: 1.5, rate: rate), into: ring, rate: rate)
        for _ in 0..<50 where log.events.withLock({ $0.filter(\.isFinal).isEmpty }) {
            try await Task.sleep(for: .milliseconds(100))
        }
        // Let the first minute close.
        try await Task.sleep(for: .seconds(1.2))
        _ = ring.write(quiet(seconds: 0.2, rate: rate))
        try await Task.sleep(for: .milliseconds(300))
        await transcriber.stop()

        let rows = reports.withLock { $0 }.map(\.row).filter { $0.channel == channel }
        try #require(!rows.isEmpty)
        #expect(rows.map(\.utterances).compactMap { $0 }.reduce(0, +) >= 1)
        #expect(rows.allSatisfy { ($0.recognize ?? 0) >= 0 && $0.cuts == 0 })
        #expect(rows.last?.partial == true)
    }

    @Test(.timeLimit(.minutes(1))) func previewsWhileTalkingThenSendsTheFinalLine() async throws {
        let rate = 48_000.0
        let events = try await run(
            quiet(seconds: 0.5, rate: rate) + talk(seconds: 2.5, rate: rate) + quiet(seconds: 1.5, rate: rate),
            rate: rate, previewInterval: .milliseconds(500)
        )
        let finalIndex = try #require(events.firstIndex { $0.isFinal })
        #expect(events[..<finalIndex].contains { !$0.isFinal && $0.text == "standby" })
        #expect(!events[(finalIndex + 1)...].contains { !$0.isFinal })
        #expect(events.filter { !$0.isFinal }.allSatisfy { abs($0.sessionOffset - events[finalIndex].sessionOffset) < 0.01 })
    }

    @Test(.timeLimit(.minutes(1))) func noPreviewsWhenOff() async throws {
        let rate = 48_000.0
        let recognizer = FakeRecognizer()
        let events = try await run(
            quiet(seconds: 0.5, rate: rate) + talk(seconds: 2.5, rate: rate) + quiet(seconds: 1.5, rate: rate),
            rate: rate, previewInterval: nil, recognizer: recognizer
        )
        #expect(recognizer.previews.withLock { $0 } == 0)
        #expect(!events.isEmpty)
        #expect(events.allSatisfy { $0.isFinal })
    }

    @Test(.timeLimit(.minutes(1))) func aShortCallIsNotPreviewed() async throws {
        let rate = 48_000.0
        let recognizer = FakeRecognizer()
        let events = try await run(
            quiet(seconds: 0.5, rate: rate) + talk(seconds: 0.4, rate: rate) + quiet(seconds: 1.5, rate: rate),
            rate: rate, previewInterval: .milliseconds(500), recognizer: recognizer
        )
        #expect(recognizer.previews.withLock { $0 } == 0)
        #expect(events.count == 1)
        #expect(events.first?.isFinal == true)
    }

    @Test(.timeLimit(.minutes(1))) func noPreviewAfterTheFinalWhenStoppedMidCall() async throws {
        let rate = 48_000.0
        let recognizer = FakeRecognizer()
        let events = try await run(
            quiet(seconds: 0.5, rate: rate) + talk(seconds: 2, rate: rate),
            rate: rate, previewInterval: .milliseconds(500), stopEarly: true, recognizer: recognizer
        )
        #expect(recognizer.previews.withLock { $0 } > 0)
        #expect(events.last?.isFinal == true)
    }

    @Test(.timeLimit(.minutes(1))) func previewsFollowAMaximumLengthCut() async throws {
        let rate = 48_000.0
        let events = try await run(
            quiet(seconds: 0.5, rate: rate) + talk(seconds: 3.5, rate: rate) + quiet(seconds: 1.5, rate: rate),
            rate: rate, previewInterval: .milliseconds(500), maximumLength: 2, finals: 2
        )
        let finals = events.indices.filter { events[$0].isFinal }
        try #require(finals.count == 2)
        let (first, second) = (finals[0], finals[1])
        #expect(events[..<first].allSatisfy { $0.isFinal || $0.sessionOffset == events[first].sessionOffset })
        #expect(events[(first + 1)..<second].allSatisfy { $0.isFinal || $0.sessionOffset == events[second].sessionOffset })
        #expect(events[(first + 1)..<second].contains { !$0.isFinal })
        #expect(!events[(second + 1)...].contains { !$0.isFinal })
    }

    /// Stopping capture mid-call still sends the call's final line, even
    /// with a model that gives up when its task is cancelled.
    @Test(.timeLimit(.minutes(1))) func stoppingMidCallStillSendsTheFinalLine() async throws {
        let rate = 48_000.0
        let events = try await run(
            quiet(seconds: 0.5, rate: rate) + talk(seconds: 2, rate: rate),
            rate: rate, previewInterval: .milliseconds(500), stopEarly: true,
            recognizer: FakeRecognizer(honoursCancellation: true)
        )
        #expect(events.last?.isFinal == true)
        #expect(events.last?.text == "standby go")
    }

    /// A previewed call whose final line comes back empty clears its
    /// italics rather than leaving words nobody will confirm.
    @Test(.timeLimit(.minutes(1))) func previewIsClearedWhenTheFinalLineIsEmpty() async throws {
        let rate = 48_000.0
        let ring = AudioRingBuffer(capacity: Int(rate) * 30)
        let log = Log()
        let transcriber = UtteranceChannelTranscriber(
            channelID: UUID(), source: AudioSource(ring: ring, sampleRate: { rate }), sessionOffset: 0,
            recognizer: FakeRecognizer(finalText: "  "), previewInterval: .milliseconds(500),
            onEvent: { event in log.events.withLock { $0.append(event) } }, onStatus: { _ in }
        )
        await transcriber.start()
        try await play(quiet(seconds: 0.5, rate: rate) + talk(seconds: 2, rate: rate) + quiet(seconds: 1.5, rate: rate),
                       into: ring, rate: rate)
        await transcriber.stop()
        let events = log.events.withLock { $0 }
        #expect(events.contains { !$0.isFinal && $0.text == "standby" })
        let last = try #require(events.last)
        #expect(!last.isFinal)
        #expect(last.text.isEmpty)
    }
}
