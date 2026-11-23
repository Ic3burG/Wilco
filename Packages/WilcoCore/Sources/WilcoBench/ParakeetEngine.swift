import FluidAudio
import Foundation
import WilcoCore
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
                let recognizer = BenchTdtRecognizer(model: BenchParakeetModel(version: .v2))
                return factory { recognizer }
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
                // One recognizer per channel over one shared store, as the app builds them.
                let store = ParakeetModelStore(directory: sharedCache)
                return factory { ParakeetRecognizer(store: store, language: nil) }
            }
        ),
        BenchEngine(
            id: "parakeet-v3-preview",
            summary: "Parakeet TDT 0.6B v3 with live preview (fast, then corrected)",
            unavailableReason: { unavailable(version: .v3, id: "parakeet-v3") },
            makeFactory: {
                let store = ParakeetModelStore(directory: sharedCache)
                return factory(previewInterval: previewInterval) { ParakeetRecognizer(store: store, language: nil) }
            }
        ),
        BenchEngine(
            id: "parakeet-v3-vocab",
            summary: "Parakeet TDT 0.6B v3 (English) with the cue words boosted by the CTC 110M model",
            unavailableReason: {
                let store = ParakeetModelStore(directory: sharedCache)
                return store.isInstalled() && store.isVocabularyInstalled()
                    ? nil : "the models aren't downloaded (wilco-bench --install parakeet-v3-vocab)"
            },
            install: { progress in
                try await ParakeetModelStore(directory: sharedCache).install(progress: progress)
            },
            makeFactory: {
                // Every channel boosts the same words, as a show's global
                // vocabulary would. English, because boosting is English only.
                // One recognizer (and boosting session) per channel over one
                // shared store, as the app builds them.
                let store = ParakeetModelStore(directory: sharedCache)
                return factory {
                    ParakeetRecognizer(store: store, language: .english, vocabulary: ClipLibrary.vocabulary)
                }
            }
        ),
    ]

    /// v3 as the app runs it with voice changes on: one recognizer per channel,
    /// one voice model shared by all of them.
    static let parakeetVoices = BenchEngine(
        id: "parakeet-v3-voices",
        summary: "Parakeet TDT 0.6B v3 with voice changes (WeSpeaker voiceprints)",
        unavailableReason: { unavailable(version: .v3, id: "parakeet-v3") ?? voiceModelMissing() },
        install: installVoiceModel,
        detectsVoiceChanges: true,
        makeFactory: {
            let store = ParakeetModelStore(directory: sharedCache)
            let voiceprints = WeSpeakerVoiceprints()
            return { channel in
                VoiceModelFirst(voiceprints: voiceprints, transcriber: UtteranceChannelTranscriber(
                    channelID: channel.id, source: channel.source, sessionOffset: 0,
                    recognizer: ParakeetRecognizer(store: store, language: nil),
                    voiceChanges: channel.voiceChanges, voiceprints: voiceprints,
                    onEvent: channel.onEvent, onStatus: channel.onStatus
                ))
            }
        }
    )

    /// As the app previews on "Fast, then corrected".
    private static let previewInterval = ChannelTranscribers.previewInterval(
        for: TranscriberConfiguration(channel: ChannelConfig(name: "Bench", engine: .parakeet), show: ShowDocument())
    )

    /// v3 with voice changes and live preview, as a new Parakeet channel runs.
    static let parakeetPreviewVoices = BenchEngine(
        id: "parakeet-v3-preview-voices",
        summary: "Parakeet TDT 0.6B v3 with live preview and voice changes",
        unavailableReason: { unavailable(version: .v3, id: "parakeet-v3") ?? voiceModelMissing() },
        install: installVoiceModel,
        detectsVoiceChanges: true,
        makeFactory: {
            let store = ParakeetModelStore(directory: sharedCache)
            let voiceprints = WeSpeakerVoiceprints()
            return { channel in
                VoiceModelFirst(voiceprints: voiceprints, transcriber: UtteranceChannelTranscriber(
                    channelID: channel.id, source: channel.source, sessionOffset: 0,
                    recognizer: ParakeetRecognizer(store: store, language: nil),
                    voiceChanges: channel.voiceChanges, voiceprints: voiceprints,
                    previewInterval: previewInterval,
                    onEvent: channel.onEvent, onStatus: channel.onStatus
                ))
            }
        }
    )

    /// FluidAudio's own model cache, so an existing download is reused.
    private static var sharedCache: URL {
        AsrModels.defaultCacheDirectory(for: .v3).deletingLastPathComponent()
    }

    private static func unavailable(version: AsrModelVersion, id: String) -> String? {
        AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: version), version: version)
            ? nil : "the model isn't downloaded (wilco-bench --install \(id))"
    }

    private static func factory(
        previewInterval: Duration? = nil, recognizer: @escaping @Sendable () -> some UtteranceRecognizer
    ) -> BenchChannelFactory {
        { channel in
            UtteranceChannelTranscriber(
                channelID: channel.id, source: channel.source, sessionOffset: 0, recognizer: recognizer(),
                previewInterval: previewInterval,
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
