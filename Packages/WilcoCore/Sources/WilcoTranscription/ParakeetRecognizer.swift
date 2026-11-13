import FluidAudio
import Foundation

public enum ParakeetLanguages {
    /// The Parakeet language for a channel's locale identifier. Empty means
    /// detect; a language the model doesn't have also gives nil.
    public static func language(for identifier: String) -> Language? {
        guard !identifier.isEmpty else { return nil }
        let code = identifier.split(whereSeparator: { $0 == "_" || $0 == "-" }).first.map { $0.lowercased() } ?? ""
        return Language(rawValue: code)
    }
}

/// Parakeet transcribes each utterance whole. All channels share one
/// `AsrManager`, which takes their utterances one at a time.
public struct ParakeetRecognizer: UtteranceRecognizer {
    let store: ParakeetModelStore
    let language: Language?

    public init(store: ParakeetModelStore, language: Language?) {
        self.store = store
        self.language = language
    }

    public func prepare() async throws {
        _ = try await store.manager()
    }

    public func recognize(_ samples: [Float]) async throws -> Recognition? {
        let manager = try await store.manager()
        // Parakeet refuses clips under a second; short calls ("Copy that.")
        // get trailing silence.
        let minimum = ASRConstants.minimumRequiredSamples(forSampleRate: 16_000)
        let audio = samples.count < minimum ? samples + [Float](repeating: 0, count: minimum - samples.count) : samples
        var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let result = try await manager.transcribe(audio, decoderState: &state, language: language)
        return Recognition(text: result.text, confidence: Double(result.confidence))
    }
}
