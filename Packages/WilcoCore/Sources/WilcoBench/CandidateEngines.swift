@preconcurrency import AVFoundation
import FluidAudio
import Foundation
import WilcoCore
import WilcoTranscription

/// Neural Engine models FluidAudio ships besides Parakeet v3, benchmarked to
/// decide whether any should join the app. None of them has app UI.
extension BenchEngine {
    static let candidates: [BenchEngine] = [
        tdt(.ultra, id: "parakeet-ultra",
            summary: "Parakeet Ultra (post-trained v3, 25 languages), one shared model"),
        tdt(.phonon2, id: "phonon-2",
            summary: "Phonon-2 (v3 retrained for the Neural Engine, English), one shared model"),
        tdt(.bark3Clean, id: "bark-3-clean",
            summary: "Bark 3.0 Clean (v3 post-train, English, drops fillers), one shared model"),
        unifiedOffline,
        streaming(id: "nemotron-1120",
                  summary: "Nemotron Speech Streaming 0.6B (English, 1.12 s chunks), one stream per channel",
                  folder: modelsRoot.appending(path: NemotronChunkSize.ms1120.repo.folderName),
                  make: { StreamingNemotronAsrManager(requestedChunkSize: .ms1120) },
                  load: { manager, folder in try await manager.loadModels(from: folder) }),
        streaming(id: "parakeet-unified-1120",
                  summary: "Parakeet Unified 0.6B streaming (English, 1.12 s latency), one stream per channel",
                  folder: modelsRoot.appending(path: Repo.parakeetUnified.folderName),
                  make: { StreamingUnifiedAsrManager(config: StreamingModelVariant.parakeetUnified1120ms.unifiedConfig!) },
                  load: { manager, folder in try await manager.loadModels(from: folder) }),
        streaming(id: "parakeet-eou-320",
                  summary: "Parakeet EOU 120M streaming (English, 320 ms chunks), one stream per channel",
                  folder: modelsRoot.appending(path: "parakeet-eou-streaming").appending(path: Repo.parakeetEou320.folderName),
                  make: { StreamingEouAsrManager(chunkSize: .ms320) },
                  load: { manager, folder in try await manager.loadModels(from: folder) }),
    ]

    /// Where FluidAudio keeps the models it downloads itself.
    private static var modelsRoot: URL {
        URL.applicationSupportDirectory.appending(path: "FluidAudio/Models", directoryHint: .isDirectory)
    }

    /// A Parakeet TDT variant with v3's contract: one model shared by every channel.
    private static func tdt(_ version: AsrModelVersion, id: String, summary: String) -> BenchEngine {
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
                let recognizer = BenchTdtRecognizer(model: BenchParakeetModel(version: version))
                return utteranceFactory { recognizer }
            }
        )
    }

    private static let unifiedOffline = BenchEngine(
        id: "parakeet-unified-offline",
        summary: "Parakeet Unified 0.6B, whole utterances (English), one shared model",
        unavailableReason: {
            let folder = modelsRoot.appending(path: Repo.parakeetUnified.folderName)
            let encoder = UnifiedModelFamily.parakeetEnglish.offlineEncoderFile(precision: .int8)
            return FileManager.default.fileExists(atPath: folder.appending(path: encoder).path)
                ? nil : "the model isn't downloaded (wilco-bench --install parakeet-unified-offline)"
        },
        install: { progress in
            try await UnifiedAsrManager().loadModels(progressHandler: { progress($0.fractionCompleted) })
        },
        makeFactory: {
            let recognizer = BenchUnifiedRecognizer(
                model: BenchUnifiedModel(folder: modelsRoot.appending(path: Repo.parakeetUnified.folderName)))
            return utteranceFactory { recognizer }
        }
    )

    /// A streaming model: each channel loads its own manager, since a stream
    /// holds state. `folder` must exist once installed.
    private static func streaming<Manager: StreamingAsrManager>(
        id: String, summary: String, folder: URL,
        make: @escaping @Sendable () -> Manager,
        load: @escaping @Sendable (Manager, URL) async throws -> Void
    ) -> BenchEngine {
        BenchEngine(
            id: id, summary: summary,
            unavailableReason: {
                FileManager.default.fileExists(atPath: folder.path)
                    ? nil : "the model isn't downloaded (wilco-bench --install \(id))"
            },
            install: { progress in
                // FluidAudio's own download; it has no progress for these.
                try await make().loadModels()
                progress(1)
            },
            makeFactory: {
                utteranceFactory(previewInterval: streamFeedInterval) {
                    StreamedUtteranceRecognizer(session: FluidStreamingSession(manager: make(), folder: folder, load: load))
                }
            }
        )
    }

    /// How often a streaming model is fed: the app's preview interval.
    private static let streamFeedInterval = ChannelTranscribers.previewInterval(
        for: TranscriberConfiguration(channel: ChannelConfig(name: "Bench", engine: .parakeet), show: ShowDocument())
    )

    private static func utteranceFactory(
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

/// Any Parakeet TDT version, one loaded model shared by its channels.
struct BenchTdtRecognizer: UtteranceRecognizer {
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

/// Loads Parakeet Unified's offline model once for every channel.
actor BenchUnifiedModel {
    let folder: URL
    private var loading: Task<UnifiedAsrManager, Error>?

    init(folder: URL) { self.folder = folder }

    func loaded() async throws -> UnifiedAsrManager {
        let folder = folder
        let task = loading ?? Task {
            let manager = UnifiedAsrManager()
            try await manager.loadModels(from: folder)
            return manager
        }
        loading = task
        do {
            return try await task.value
        } catch {
            loading = nil
            throw error
        }
    }
}

struct BenchUnifiedRecognizer: UtteranceRecognizer {
    let model: BenchUnifiedModel

    func prepare() async throws {
        _ = try await model.loaded()
    }

    func recognize(_ samples: [Float]) async throws -> Recognition? {
        let text = try await model.loaded().transcribe(samples)
        return Recognition(text: text, confidence: nil)
    }
}

/// A FluidAudio streaming manager as a ``StreamingSession``.
struct FluidStreamingSession<Manager: StreamingAsrManager>: StreamingSession {
    let manager: Manager
    let folder: URL
    let load: @Sendable (Manager, URL) async throws -> Void

    func load() async throws {
        try await load(manager, folder)
    }

    func append(_ samples: [Float]) async throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        try await manager.appendAudio(buffer)
        try await manager.processBufferedAudio()
    }

    func partial() async -> String {
        await manager.getPartialTranscript()
    }

    func finish() async throws -> String {
        try await manager.finish()
    }

    func reset() async throws {
        try await manager.reset()
    }
}
