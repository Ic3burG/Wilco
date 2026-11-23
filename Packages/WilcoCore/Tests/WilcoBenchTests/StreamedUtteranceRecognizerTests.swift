import Testing
import WilcoTranscription
@testable import WilcoBench

/// Records what a streaming model was given; its "transcript" is the count of
/// samples received since the last reset.
private actor RecordingSession: StreamingSession {
    var appended: [[Float]] = []
    var resets = 0
    var failFinish = false
    private var received = 0

    func load() async throws {}
    func append(_ samples: [Float]) async throws {
        appended.append(samples)
        received += samples.count
    }
    func partial() async -> String { received == 0 ? "" : "\(received)" }
    func finish() async throws -> String {
        if failFinish { throw CancellationError() }
        return "\(received)"
    }
    func reset() async throws {
        resets += 1
        received = 0
    }
    func setFailFinish() { failFinish = true }
}

@Suite("Streamed utterance recognizer")
struct StreamedUtteranceRecognizerTests {
    private func samples(_ count: Int) -> [Float] { (0..<count).map(Float.init) }

    @Test func previewsFeedOnlyNewAudio() async throws {
        let session = RecordingSession()
        let recognizer = StreamedUtteranceRecognizer(session: session)
        #expect(await recognizer.preview(samples(100))?.text == "100")
        #expect(await recognizer.preview(samples(250))?.text == "250")
        let final = try await recognizer.recognize(samples(300))
        #expect(final?.text == "300")
        let appended = await session.appended
        #expect(appended == [samples(100), Array(samples(250)[100...]), Array(samples(300)[250...])])
    }

    @Test func eachUtteranceStartsAFreshStream() async throws {
        let session = RecordingSession()
        let recognizer = StreamedUtteranceRecognizer(session: session)
        _ = try await recognizer.recognize(samples(300))
        #expect(await recognizer.preview(samples(80))?.text == "80")
        #expect(try await recognizer.recognize(samples(120))?.text == "120")
        #expect(await session.resets == 2)
    }

    @Test func repeatedPreviewOfTheSameAudioFeedsNothing() async {
        let session = RecordingSession()
        let recognizer = StreamedUtteranceRecognizer(session: session)
        _ = await recognizer.preview(samples(100))
        _ = await recognizer.preview(samples(100))
        #expect(await session.appended.count == 1)
    }

    @Test func aShorterUtteranceWithoutAFinalRestartsTheStream() async {
        let session = RecordingSession()
        let recognizer = StreamedUtteranceRecognizer(session: session)
        _ = await recognizer.preview(samples(500))
        #expect(await recognizer.preview(samples(50))?.text == "50")
        #expect(await session.resets == 1)
    }

    @Test func aFailedFinalStillResetsTheStream() async {
        let session = RecordingSession()
        await session.setFailFinish()
        let recognizer = StreamedUtteranceRecognizer(session: session)
        await #expect(throws: CancellationError.self) { try await recognizer.recognize(samples(100)) }
        #expect(await session.resets == 1)
        #expect(await recognizer.preview(samples(40))?.text == "40")
    }
}
