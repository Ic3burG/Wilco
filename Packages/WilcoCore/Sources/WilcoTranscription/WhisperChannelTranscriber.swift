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
        _ samples: [Float], model: WhisperModel, language: String?, vocabulary: [String], translate: Bool,
        wordTimestamps: Bool = false
    ) async throws -> [TranscriptionResult] {
        let kit = try await kit(for: model)
        var options = DecodingOptions(
            // Whisper's translate task always produces English.
            task: translate ? .translate : .transcribe,
            language: language,
            detectLanguage: language == nil,
            skipSpecialTokens: true,
            // Word times (for splitting lines where the voice changes) need
            // the timestamp tokens too.
            withoutTimestamps: !wordTimestamps,
            wordTimestamps: wordTimestamps
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
    /// Nil when the channel doesn't detect voice changes.
    private let annotator: VoiceAnnotator?
    private var voices: VoiceAnnotationQueue?
    private var clips: ChannelClips?
    private var pump: Task<Void, Never>?
    private var meter: ChannelMeter?

    init(
        configuration: TranscriberConfiguration, source: AudioSource, sessionOffset: Double,
        models: WhisperModelStore, voiceprints: (any VoiceprintExtractor)?,
        onEvent: @escaping TranscriptionHandler, onStatus: @escaping StatusHandler
    ) {
        self.configuration = configuration
        self.source = source
        self.sessionOffset = sessionOffset
        self.models = models
        self.onEvent = onEvent
        self.onStatus = onStatus
        annotator = configuration.voiceChanges.map {
            VoiceAnnotator(settings: $0, extractor: voiceprints ?? UnavailableVoiceprints())
        }
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
        meter = source.diagnostics.map {
            ChannelMeter(channelID: configuration.channelID, tap: $0, countsUtterances: true)
        }
        onStatus(.listening)
        voices = annotator.map { VoiceAnnotationQueue(annotator: $0, onEvent: onEvent) }
        clips = source.clips.map {
            ChannelClips(
                clipSwitch: $0, channel: configuration.channelID, engine: SpeechEngine.whisper.rawValue,
                whisperModel: configuration.whisperModel.rawValue
            )
        }
        pump = Task { await self.run() }
    }

    func stop() async {
        pump?.cancel()
        await pump?.value
        pump = nil
        meter?.finish(at: Date())
        meter = nil
        // Lines already sent to rules still get their voice.
        await voices?.finish()
        voices = nil
    }

    func updateVoiceSettings(_ settings: VoiceChangeSettings) async {
        await annotator?.update(settings: settings)
    }

    private func run() async {
        let converter = SampleRateConverter.whisper()
        var segmenter = UtteranceSegmenter(sampleRate: 16_000)
        // No language means Whisper detects it from each utterance.
        let language = configuration.localeIdentifier.isEmpty
            ? nil
            : Locale(identifier: configuration.localeIdentifier).language.languageCode?.identifier

        while !Task.isCancelled {
            let samples = source.read(metering: &meter)
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
        let clock = ContinuousClock()
        let began = clock.now
        let transcribed = try? await models.transcribe(
            utterance.samples, model: configuration.whisperModel,
            language: language, vocabulary: configuration.vocabulary,
            translate: configuration.translateToEnglish,
            // Word times cost Whisper time; only ask when voice analysis can use them.
            wordTimestamps: annotator?.isUsable == true
        )
        meter?.recognized(
            modelSeconds: (clock.now - began) / .seconds(1),
            audioSeconds: Double(utterance.samples.count) / 16_000, cut: utterance.wasCut
        )
        guard let results = transcribed else { return }
        let segments = results.flatMap(\.segments)
        let text = segments.map(\.text).joined().trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        let confidence = segments.isEmpty ? nil
            : Double(segments.map { exp($0.avgLogprob) }.reduce(0, +)) / Double(segments.count)
        let start = sessionOffset + utterance.startOffset
        let line = TranscriptionEvent(
            channelID: configuration.channelID,
            text: text,
            isFinal: true,
            sessionOffset: start,
            confidence: confidence
        )
        deliverFinalLine(
            line, voices: voices, onEvent: onEvent,
            lineStart: start, lineEnd: start + Double(utterance.samples.count) / 16_000,
            words: Self.words(in: segments, from: start),
            audio: { utterance.samples },
            clips: clips
        )
    }

    /// The segments' words, moved from seconds into the utterance to session
    /// offsets. Empty when Whisper gave no word times.
    static func words(in segments: [TranscriptionSegment], from start: Double) -> [TimedWord] {
        segments.flatMap { $0.words ?? [] }.map {
            TimedWord(text: $0.word, start: start + Double($0.start), end: start + Double($0.end))
        }
    }
}
