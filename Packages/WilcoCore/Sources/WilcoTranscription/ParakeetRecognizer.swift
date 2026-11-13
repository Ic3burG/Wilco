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
    /// Boosts the channel's vocabulary; nil when it doesn't apply.
    let booster: ParakeetBooster?

    public init(store: ParakeetModelStore, language: Language?, vocabulary: [String] = []) {
        self.store = store
        self.language = language
        booster = ParakeetVocabulary.applies(language: language, terms: vocabulary)
            ? ParakeetBooster(store: store, terms: vocabulary) : nil
    }

    public func prepare() async throws {
        _ = try await store.manager()
        // Load the vocabulary model now rather than on the first call.
        _ = await booster?.current()
    }

    public func recognize(_ samples: [Float]) async throws -> Recognition? {
        let manager = try await store.manager()
        // Parakeet refuses clips under a second; short calls ("Copy that.")
        // get trailing silence.
        let minimum = ASRConstants.minimumRequiredSamples(forSampleRate: 16_000)
        let audio = samples.count < minimum ? samples + [Float](repeating: 0, count: minimum - samples.count) : samples
        var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let result = try await manager.transcribe(audio, decoderState: &state, language: language)
        var text = result.text
        if let session = await booster?.current(),
           let timings = result.tokenTimings, !timings.isEmpty,
           // With 10 terms or fewer this is always true; larger
           // vocabularies skip the CTC pass when no word is close to a term.
           session.hasCTCRescoringCandidates(text: text, tokenTimings: timings),
           // Without a replacement, rescore hands back `text` unchanged,
           // which `accepts` refuses.
           let rescored = await session.rescore(text: text, tokenTimings: timings, audioSamples: audio),
           ParakeetVocabulary.accepts(original: text, rescored: rescored.text) {
            text = rescored.text
        }
        return Recognition(text: text, confidence: Double(result.confidence))
    }
}
