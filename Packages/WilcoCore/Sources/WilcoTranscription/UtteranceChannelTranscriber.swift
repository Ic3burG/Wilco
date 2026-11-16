import Foundation
import WilcoCore

/// What a recognizer heard in one utterance.
public struct Recognition: Sendable, Equatable {
    public var text: String
    /// 0 to 1, when the model gives one.
    public var confidence: Double?
    /// The words of `text` with their times, in seconds from the start of the
    /// utterance's audio. Empty when the model doesn't give them; the line
    /// then can't be split where the voice changes.
    public var words: [TimedWord]

    public init(text: String, confidence: Double?, words: [TimedWord] = []) {
        self.text = text
        self.confidence = confidence
        self.words = words
    }
}

/// A speech model that transcribes a whole utterance at a time, as opposed
/// to streaming words while someone talks.
///
/// Conform a new model to this to run it through
/// ``UtteranceChannelTranscriber``, which does the audio side: reading the
/// channel, resampling and cutting at pauses. One recognizer can serve every
/// channel, so a model is loaded once.
public protocol UtteranceRecognizer: Sendable {
    /// Loads the model. Called by every channel as it starts; load only once.
    func prepare() async throws
    /// Transcribes one utterance of 16 kHz mono audio. Nil or empty text
    /// means nothing was said.
    func recognize(_ samples: [Float]) async throws -> Recognition?
}

/// Transcribes a channel with an ``UtteranceRecognizer``: cuts the stream
/// into utterances at pauses and transcribes each one whole. Lines arrive
/// final, with no volatile preview.
public actor UtteranceChannelTranscriber: ChannelTranscriber {
    private let channelID: UUID
    private let source: AudioSource
    private let sessionOffset: Double
    private let recognizer: any UtteranceRecognizer
    private let onEvent: TranscriptionHandler
    private let onStatus: StatusHandler
    /// Nil when the channel doesn't detect voice changes.
    private let annotator: VoiceAnnotator?
    private var voices: VoiceAnnotationQueue?
    private var pump: Task<Void, Never>?

    /// With `voiceChanges` set, each line goes out `.recognized` and then
    /// `.annotated` with its voice letter; `voiceprints` is the app's shared
    /// voice model (nil leaves lines without letters).
    public init(
        channelID: UUID, source: AudioSource, sessionOffset: Double, recognizer: any UtteranceRecognizer,
        voiceChanges: VoiceChangeSettings? = nil, voiceprints: (any VoiceprintExtractor)? = nil,
        onEvent: @escaping TranscriptionHandler, onStatus: @escaping StatusHandler
    ) {
        self.channelID = channelID
        self.source = source
        self.sessionOffset = sessionOffset
        self.recognizer = recognizer
        self.onEvent = onEvent
        self.onStatus = onStatus
        annotator = voiceChanges.map { VoiceAnnotator(settings: $0, extractor: voiceprints ?? UnavailableVoiceprints()) }
    }

    public func start() async {
        onStatus(.preparing)
        do {
            try await recognizer.prepare()
        } catch {
            onStatus(.failed("Could not load the speech model: \(error.localizedDescription)"))
            return
        }
        // Discard audio that queued while the model loaded.
        _ = source.ring.read(maxCount: source.ring.availableToRead)
        onStatus(.listening)
        voices = annotator.map { VoiceAnnotationQueue(annotator: $0, onEvent: onEvent) }
        pump = Task { await self.run() }
    }

    public func stop() async {
        pump?.cancel()
        await pump?.value
        pump = nil
        // Lines already sent to rules still get their voice.
        await voices?.finish()
        voices = nil
    }

    private func run() async {
        let converter = SampleRateConverter.whisper()
        var segmenter = UtteranceSegmenter(sampleRate: 16_000)
        while !Task.isCancelled {
            let samples = source.ring.read(maxCount: source.ring.availableToRead)
            if !samples.isEmpty, let resampled = try? converter.convertToSamples(samples, sampleRate: source.sampleRate()) {
                for utterance in segmenter.append(resampled) {
                    await transcribe(utterance)
                }
            }
            try? await Task.sleep(for: pumpInterval)
        }
        if let last = segmenter.flush() {
            await transcribe(last)
        }
    }

    private func transcribe(_ utterance: UtteranceSegmenter.Utterance) async {
        guard let recognition = try? await recognizer.recognize(utterance.samples) else { return }
        let text = recognition.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let start = sessionOffset + utterance.startOffset
        let line = TranscriptionEvent(
            channelID: channelID,
            text: text,
            isFinal: true,
            sessionOffset: start,
            confidence: recognition.confidence
        )
        deliverFinalLine(
            line, voices: voices, onEvent: onEvent,
            lineStart: start, lineEnd: start + Double(utterance.samples.count) / 16_000,
            words: recognition.words.map { TimedWord(text: $0.text, start: start + $0.start, end: start + $0.end) },
            audio: { utterance.samples }
        )
    }
}
