import Foundation
import WhisperKit
import WilcoCore

/// Loads Whisper models once and shares them between channels. Transcription
/// runs one utterance at a time through each model.
public actor WhisperModelStore {
    private let downloadBase: URL
    private var loaded: [WhisperModel: WhisperKit] = [:]
    /// A load in progress, so channels starting together load a model once.
    private var loading: [WhisperModel: Task<Void, Error>] = [:]

    public init(downloadBase: URL = DataLocations.whisperModels) {
        self.downloadBase = downloadBase
    }

    /// Where WhisperKit keeps a model under `downloadBase` (WhisperKit's standard layout).
    public nonisolated func folder(for model: WhisperModel) -> URL {
        downloadBase.appending(path: "models/argmaxinc/whisperkit-coreml/\(model.variant)", directoryHint: .isDirectory)
    }

    public nonisolated func isDownloaded(_ model: WhisperModel) -> Bool {
        FileManager.default.fileExists(atPath: folder(for: model).appending(path: "config.json").path)
    }

    /// Fetches a model ahead of a show, so the first utterance isn't held up.
    public nonisolated func download(
        _ model: WhisperModel, progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        _ = try await WhisperKit.download(
            variant: model.variant,
            downloadBase: downloadBase,
            from: "argmaxinc/whisperkit-coreml",
            progressCallback: { progress($0.fractionCompleted) }
        )
    }

    /// Deletes a downloaded model. Don't remove the one channels are using.
    public nonisolated func remove(_ model: WhisperModel) throws {
        let folder = folder(for: model)
        guard FileManager.default.fileExists(atPath: folder.path) else { return }
        try FileManager.default.removeItem(at: folder)
    }

    /// Bytes the model takes on disk, or nil when it isn't downloaded.
    public nonisolated func sizeOnDisk(of model: WhisperModel) -> Int64? {
        guard isDownloaded(model),
              let files = FileManager.default.enumerator(
                  at: folder(for: model), includingPropertiesForKeys: [.totalFileAllocatedSizeKey]
              )
        else { return nil }
        var total: Int64 = 0
        for case let file as URL in files {
            total += Int64((try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    func prepare(_ model: WhisperModel) async throws {
        _ = try await kit(for: model)
    }

    func transcribe(
        _ samples: [Float], model: WhisperModel, language: String?, vocabulary: [String], translate: Bool
    ) async throws -> [TranscriptionResult] {
        let kit = try await kit(for: model)
        var options = DecodingOptions(
            // Whisper's translate task always produces English.
            task: translate ? .translate : .transcribe,
            language: language,
            detectLanguage: language == nil,
            skipSpecialTokens: true,
            withoutTimestamps: true
        )
        if let tokenizer = kit.tokenizer, !vocabulary.isEmpty {
            // A prompt of the expected terms nudges spelling of names and jargon.
            options.promptTokens = tokenizer.encode(text: " " + vocabulary.joined(separator: ", "))
                .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
        }
        return try await kit.transcribe(audioArray: samples, decodeOptions: options)
    }

    private func kit(for model: WhisperModel) async throws -> WhisperKit {
        if let kit = loaded[model] { return kit }
        if loading[model] == nil {
            loading[model] = startLoading(model)
        }
        do {
            try await loading[model]?.value
        } catch {
            loading[model] = nil
            throw error
        }
        loading[model] = nil
        guard let kit = loaded[model] else { throw TranscriberError("The Whisper model did not load") }
        return kit
    }

    /// Runs on this actor, so the loaded model never leaves it.
    private func startLoading(_ model: WhisperModel) -> Task<Void, Error> {
        let local = isDownloaded(model)
        let config = WhisperKitConfig(
            model: model.variant,
            downloadBase: downloadBase,
            modelRepo: "argmaxinc/whisperkit-coreml",
            // Use files already on disk without asking the network first.
            modelFolder: local ? folder(for: model).path : nil,
            verbose: false,
            logLevel: .error,
            prewarm: true,
            load: true,
            download: !local
        )
        return Task {
            self.loaded[model] = try await WhisperKit(config)
        }
    }
}

/// Transcribes a channel with Whisper: cuts the stream into utterances at
/// pauses and transcribes each one whole. Lines arrive final, with no
/// volatile preview.
actor WhisperChannelTranscriber: ChannelTranscriber {
    private let configuration: TranscriberConfiguration
    private let source: AudioSource
    private let sessionOffset: Double
    private let models: WhisperModelStore
    private let onEvent: TranscriptionHandler
    private let onStatus: StatusHandler
    private var pump: Task<Void, Never>?

    init(
        configuration: TranscriberConfiguration, source: AudioSource, sessionOffset: Double,
        models: WhisperModelStore, onEvent: @escaping TranscriptionHandler, onStatus: @escaping StatusHandler
    ) {
        self.configuration = configuration
        self.source = source
        self.sessionOffset = sessionOffset
        self.models = models
        self.onEvent = onEvent
        self.onStatus = onStatus
    }

    func start() async {
        onStatus(.preparing)
        do {
            try await models.prepare(configuration.whisperModel)
        } catch {
            onStatus(.failed("Could not load the Whisper model: \(error.localizedDescription)"))
            return
        }
        // Discard audio that queued while the model loaded.
        _ = source.ring.read(maxCount: source.ring.availableToRead)
        onStatus(.listening)
        pump = Task { await self.run() }
    }

    func stop() async {
        pump?.cancel()
        await pump?.value
        pump = nil
    }

    private func run() async {
        let converter = SampleRateConverter.whisper()
        var segmenter = UtteranceSegmenter(sampleRate: 16_000)
        // No language means Whisper detects it from each utterance.
        let language = configuration.localeIdentifier.isEmpty
            ? nil
            : Locale(identifier: configuration.localeIdentifier).language.languageCode?.identifier

        while !Task.isCancelled {
            let samples = source.ring.read(maxCount: source.ring.availableToRead)
            if !samples.isEmpty, let resampled = try? converter.convertToSamples(samples, sampleRate: source.sampleRate()) {
                for utterance in segmenter.append(resampled) {
                    await transcribe(utterance, language: language)
                }
            }
            try? await Task.sleep(for: pumpInterval)
        }
        if let last = segmenter.flush() {
            await transcribe(last, language: language)
        }
    }

    private func transcribe(_ utterance: UtteranceSegmenter.Utterance, language: String?) async {
        guard let results = try? await models.transcribe(
            utterance.samples, model: configuration.whisperModel,
            language: language, vocabulary: configuration.vocabulary,
            translate: configuration.translateToEnglish
        ) else { return }
        let segments = results.flatMap(\.segments)
        let text = segments.map(\.text).joined().trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        let confidence = segments.isEmpty ? nil
            : Double(segments.map { exp($0.avgLogprob) }.reduce(0, +)) / Double(segments.count)
        onEvent(TranscriptionEvent(
            channelID: configuration.channelID,
            text: text,
            isFinal: true,
            sessionOffset: sessionOffset + utterance.startOffset,
            confidence: confidence
        ))
    }
}
