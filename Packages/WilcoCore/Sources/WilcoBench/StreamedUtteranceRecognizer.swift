import Foundation
import WilcoTranscription

/// One stream of a streaming speech model: audio goes in a piece at a time
/// and the words so far can be read back at any point.
protocol StreamingSession: Sendable {
    func load() async throws
    /// Adds audio (16 kHz mono) and decodes whatever it completes.
    func append(_ samples: [Float]) async throws
    func partial() async -> String
    /// Decodes what's left and returns the whole transcript since the last reset.
    func finish() async throws -> String
    /// Clears the stream for the next utterance. The model stays loaded.
    func reset() async throws
}

/// Runs a streaming model behind the same pause-cut utterances as every other
/// engine, so the delays compare fairly. Each preview passes the utterance so
/// far; only the audio the model hasn't had yet is fed, so the work is spread
/// across the utterance and the final line only has the tail left to decode.
/// One per channel: a stream holds that channel's state.
actor StreamedUtteranceRecognizer: UtteranceRecognizer {
    private let session: any StreamingSession
    /// Samples of the current utterance already given to the model.
    private var fed = 0

    init(session: any StreamingSession) {
        self.session = session
    }

    func prepare() async throws {
        try await session.load()
    }

    func preview(_ samples: [Float]) async -> Recognition? {
        do {
            try await feed(samples)
        } catch {
            return nil
        }
        let text = await session.partial()
        return text.isEmpty ? nil : Recognition(text: text, confidence: nil)
    }

    func recognize(_ samples: [Float]) async throws -> Recognition? {
        let text: String
        do {
            try await feed(samples)
            text = try await session.finish()
        } catch {
            try? await clear()
            throw error
        }
        try await clear()
        return Recognition(text: text, confidence: nil)
    }

    private func feed(_ samples: [Float]) async throws {
        // Shorter than what was fed means a new utterance whose previous one
        // never got a final call; start that stream again.
        if samples.count < fed { try await clear() }
        guard samples.count > fed else { return }
        let fresh = Array(samples[fed...])
        fed = samples.count
        try await session.append(fresh)
    }

    private func clear() async throws {
        fed = 0
        try await session.reset()
    }
}
