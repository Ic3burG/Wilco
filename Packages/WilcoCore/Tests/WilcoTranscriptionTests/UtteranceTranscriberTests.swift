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
        let failPrepare: Bool
        init(failPrepare: Bool = false) { self.failPrepare = failPrepare }

        func prepare() async throws {
            prepared.withLock { $0 += 1 }
            if failPrepare { throw TranscriberError("no model") }
        }

        func recognize(_ samples: [Float]) async throws -> Recognition? {
            heard.withLock { $0.append(samples.count) }
            return Recognition(text: " standby go ", confidence: 0.9)
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
}
