import FluidAudio
import Foundation
import WilcoTranscription

/// NVIDIA Parakeet TDT through FluidAudio, on the Neural Engine. v3 is the
/// app's model; v2 (English only) is benchmarked for comparison.
extension BenchEngine {
    static let parakeet: [BenchEngine] = [
        BenchEngine(
            id: "parakeet-v2",
            summary: "Parakeet TDT 0.6B v2 (English), one model shared by every channel",
            unavailableReason: { unavailable(version: .v2, id: "parakeet-v2") },
            install: { progress in
                _ = try await AsrModels.download(version: .v2) { progress($0.fractionCompleted) }
            },
            makeFactory: {
                // A fresh model per run, so each run pays its own load.
                factory(recognizer: BenchV2Recognizer(model: BenchParakeetModel(version: .v2)))
            }
        ),
        BenchEngine(
            id: "parakeet-v3",
            summary: "Parakeet TDT 0.6B v3 (25 languages), one model shared by every channel",
            unavailableReason: { unavailable(version: .v3, id: "parakeet-v3") },
            install: { progress in
                _ = try await AsrModels.download(version: .v3) { progress($0.fractionCompleted) }
            },
            makeFactory: {
                // The app's recognizer, reading FluidAudio's own cache so an
                // existing download is reused.
                let cache = AsrModels.defaultCacheDirectory(for: .v3).deletingLastPathComponent()
                return factory(recognizer: ParakeetRecognizer(store: ParakeetModelStore(directory: cache), language: nil))
            }
        ),
    ]

    private static func unavailable(version: AsrModelVersion, id: String) -> String? {
        AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: version), version: version)
            ? nil : "the model isn't downloaded (wilco-bench --install \(id))"
    }

    private static func factory(recognizer: some UtteranceRecognizer) -> BenchChannelFactory {
        { channel in
            UtteranceChannelTranscriber(
                channelID: channel.id, source: channel.source, sessionOffset: 0, recognizer: recognizer,
                onEvent: channel.onEvent, onStatus: channel.onStatus
            )
        }
    }
}

/// Loads a Parakeet model once for every channel that asks. Bench only: the
/// app's store handles v3.
actor BenchParakeetModel {
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

struct BenchV2Recognizer: UtteranceRecognizer {
    let model: BenchParakeetModel

    func prepare() async throws {
        _ = try await model.loaded()
    }

    func recognize(_ samples: [Float]) async throws -> Recognition? {
        let manager = try await model.loaded()
        let minimum = ASRConstants.minimumRequiredSamples(forSampleRate: 16_000)
        let audio = samples.count < minimum ? samples + [Float](repeating: 0, count: minimum - samples.count) : samples
        var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let result = try await manager.transcribe(audio, decoderState: &state)
        return Recognition(text: result.text, confidence: Double(result.confidence))
    }
}
