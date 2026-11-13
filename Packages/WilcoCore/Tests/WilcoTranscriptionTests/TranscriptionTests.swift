import AVFoundation
import Foundation
import Synchronization
import Testing
import WilcoCore
@testable import WilcoTranscription

@Suite("Sample rate converter")
struct SampleRateConverterTests {
    @Test func streamsFortyEightKilohertzToSixteen() throws {
        let converter = SampleRateConverter.whisper()
        let chunk = [Float](repeating: 0.1, count: 4_800)  // 100 ms

        // The resampling filter looks ahead and releases output in blocks, so
        // a little audio always waits for the next chunk. That delay must stay
        // small (here under 25 ms) for the whole stream, never growing.
        var produced = 0
        for second in 1...3 {
            for _ in 0..<10 {
                produced += try converter.convertToSamples(chunk, sampleRate: 48_000).count
            }
            let delay = second * 16_000 - produced
            #expect((0..<400).contains(delay), "after \(second) s the converter held back \(delay) frames")
        }
    }

    @Test func unknownSampleRateProducesNothing() throws {
        let converter = SampleRateConverter.whisper()
        #expect(try converter.convertToSamples([0.1, 0.2], sampleRate: 0).isEmpty)
    }
}

/// End-to-end recognition of speech rendered by macOS `say`. Needs speech
/// models on this Mac and takes several seconds, so it runs only with
/// `WILCO_ASR_TESTS=1`.
@Suite("Speech recognition", .enabled(if: ProcessInfo.processInfo.environment["WILCO_ASR_TESTS"] == "1"))
struct RecognitionTests {
    private final class Events: Sendable {
        let events = Mutex<[TranscriptionEvent]>([])
        let statuses = Mutex<[TranscriberStatus]>([])
        var finals: [TranscriptionEvent] { events.withLock { $0.filter(\.isFinal) } }
    }

    /// Mono float samples of `text` spoken by the system voice at 48 kHz.
    private func spoken(_ text: String, voice: String? = nil) throws -> [Float] {
        let url = FileManager.default.temporaryDirectory.appending(path: "say-\(UUID().uuidString).wav")
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-o", url.path, "--file-format=WAVE", "--data-format=LEF32@48000"]
            + (voice.map { ["-v", $0] } ?? []) + [text]
        try say.run()
        say.waitUntilExit()
        let file = try AVAudioFile(forReading: url)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    }

    private func transcribe(
        _ engine: SpeechEngine,
        saying text: String = "Standby lighting cue five.",
        voice: String? = nil,
        language: String = "en_US",
        translate: Bool = false
    ) async throws -> [TranscriptionEvent] {
        var show = ShowDocument()
        var channel = show.addChannel(engine: engine)
        channel.localeIdentifier = language
        channel.translateToEnglish = translate
        channel.latencyProfile = .leadAndCorrect
        let configuration = TranscriberConfiguration(channel: channel, show: show)

        let ring = AudioRingBuffer(capacity: 48_000 * 20)
        let events = Events()
        let transcriber = ChannelTranscribers.make(
            configuration: configuration,
            source: AudioSource(ring: ring, sampleRate: { 48_000 }),
            sessionOffset: 0,
            whisperModels: WhisperModelStore(),
            onEvent: { event in events.events.withLock { $0.append(event) } },
            onStatus: { status in events.statuses.withLock { $0.append(status) } }
        )
        await transcriber.start()
        #expect(events.statuses.withLock { $0.last } == .listening)

        // Feed in real time: speech, then a pause so the utterance closes.
        let audio = try spoken(text, voice: voice) + [Float](repeating: 0, count: 48_000 * 2)
        for chunk in stride(from: 0, to: audio.count, by: 4_800) {
            ring.write(Array(audio[chunk..<min(chunk + 4_800, audio.count)]))
            try await Task.sleep(for: .milliseconds(100))
        }
        try await Task.sleep(for: .seconds(2))
        await transcriber.stop()
        return events.events.withLock { $0 }
    }

    private func expectHeard(_ events: [TranscriptionEvent]) {
        let text = events.filter(\.isFinal).map(\.text).joined(separator: " ").lowercased()
        #expect(text.contains("standby") || text.contains("stand by"), "heard: \(text)")
        #expect(text.contains("lighting"), "heard: \(text)")
        // Both engines write the cue the way lighting desks do: "Q5".
        #expect(["cue five", "cue 5", "q5", "q 5", "queue 5"].contains { text.contains($0) }, "heard: \(text)")
    }

    @Test func whisperHearsACueCall() async throws {
        try #require(WhisperModelStore().isDownloaded(.base), "Whisper base model is not downloaded")
        expectHeard(try await transcribe(.whisper))
    }

    @Test func whisperDetectsFrenchAndTranslatesItToEnglish() async throws {
        try #require(WhisperModelStore().isDownloaded(.base), "Whisper base model is not downloaded")
        let events = try await transcribe(
            .whisper, saying: "Bonjour. Le spectacle commence dans cinq minutes.",
            voice: "Thomas", language: "", translate: true
        )
        let text = events.filter(\.isFinal).map(\.text).joined(separator: " ").lowercased()
        #expect(text.contains("minutes"), "heard: \(text)")
        #expect(!text.contains("commence dans"), "still French: \(text)")
    }

    /// A channel whose device never delivered audio (an interface that isn't
    /// running) must still stop: a stuck stop left other transcribers running.
    @Test(.timeLimit(.minutes(1))) func appleStopsAfterReceivingNoAudio() async throws {
        guard #available(macOS 26, *) else { return }
        var show = ShowDocument()
        var channel = show.addChannel(engine: .longForm)
        channel.localeIdentifier = "en_US"
        let ring = AudioRingBuffer(capacity: 48_000 * 20)
        let transcriber = ChannelTranscribers.make(
            configuration: TranscriberConfiguration(channel: channel, show: show),
            source: AudioSource(ring: ring, sampleRate: { 48_000 }),
            sessionOffset: 0, whisperModels: WhisperModelStore(),
            onEvent: { _ in }, onStatus: { _ in }
        )
        await transcriber.start()
        try await Task.sleep(for: .seconds(2))
        let stopped = Mutex(false)
        let stopping = Task { await transcriber.stop(); stopped.withLock { $0 = true } }
        for _ in 0..<100 where !stopped.withLock({ $0 }) {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(stopped.withLock { $0 }, "stop() did not return within 10 s")
        stopping.cancel()
    }

    @Test func appleLongFormHearsACueCall() async throws {
        guard #available(macOS 26, *) else { return }
        let events = try await transcribe(.longForm)
        expectHeard(events)
        #expect(events.contains { !$0.isFinal }, "expected volatile results before the final line")
    }
}
