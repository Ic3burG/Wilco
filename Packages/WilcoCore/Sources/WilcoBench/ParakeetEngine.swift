import FluidAudio
import Foundation
import WilcoTranscription

/// NVIDIA Parakeet TDT through FluidAudio, on the Neural Engine. Benchmark
/// only for now: the app doesn't link FluidAudio.
extension BenchEngine {
    static let parakeet: [BenchEngine] = [
        parakeet(id: "parakeet-v2", version: .v2, summary: "Parakeet TDT 0.6B v2 (English), one model shared by every channel"),
        parakeet(id: "parakeet-v3", version: .v3, summary: "Parakeet TDT 0.6B v3 (25 languages), one model shared by every channel"),
    ]

    private static func parakeet(id: String, version: AsrModelVersion, summary: String) -> BenchEngine {
        BenchEngine(
            id: id, summary: summary,
            unavailableReason: {
                AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: version), version: version)
                    ? nil : "the model isn't downloaded (wilco-bench --install \(id))"
            },
            install: { progress in
                _ = try await AsrModels.download(version: version) { progress($0.fractionCompleted) }
            },
            makeFactory: {
                // A fresh model per run, so each run pays its own load.
                let recognizer = ParakeetRecognizer(model: ParakeetModel(version: version))
                return { channel in
                    UtteranceChannelTranscriber(
                        channelID: channel.id, source: channel.source, sessionOffset: 0, recognizer: recognizer,
                        onEvent: channel.onEvent, onStatus: channel.onStatus
                    )
                }
            }
        )
    }
}

/// Loads a Parakeet model once for every channel that asks.
actor ParakeetModel {
    let version: AsrModelVersion
    private var manager: AsrManager?
    private var loading: Task<AsrManager, Error>?

    init(version: AsrModelVersion) { self.version = version }

    func loaded() async throws -> AsrManager {
        if let manager { return manager }
        let version = version
        let task = loading ?? Task {
            let models = try await AsrModels.load(from: AsrModels.defaultCacheDirectory(for: version), version: version)
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            return manager
        }
        loading = task
        do {
            let manager = try await task.value
            self.manager = manager
            return manager
        } catch {
            loading = nil
            throw error
        }
    }
}

/// Parakeet transcribes each utterance whole. All channels share one
/// `AsrManager`, which takes their utterances one at a time.
struct ParakeetRecognizer: UtteranceRecognizer {
    let model: ParakeetModel

    func prepare() async throws {
        _ = try await model.loaded()
    }

    func recognize(_ samples: [Float]) async throws -> Recognition? {
        let manager = try await model.loaded()
        // Parakeet refuses clips under a second; short calls ("Copy that.")
        // get trailing silence.
        let minimum = ASRConstants.minimumRequiredSamples(forSampleRate: 16_000)
        let audio = samples.count < minimum ? samples + [Float](repeating: 0, count: minimum - samples.count) : samples
        var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let result = try await manager.transcribe(audio, decoderState: &state)
        return Recognition(text: result.text, confidence: Double(result.confidence))
    }
}
