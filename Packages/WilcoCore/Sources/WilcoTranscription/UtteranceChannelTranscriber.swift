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
    /// A quick look at an utterance still being spoken, shown as words in
    /// progress. Nil skips this preview; it never throws, and it must not
    /// hold up `recognize`.
    func preview(_ samples: [Float]) async -> Recognition?
}

extension UtteranceRecognizer {
    /// Models without previews send only final lines.
    public func preview(_ samples: [Float]) async -> Recognition? { nil }
}

/// Transcribes a channel with an ``UtteranceRecognizer``: cuts the stream
/// into utterances at pauses and transcribes each one whole. Lines arrive
/// final; with a preview interval, the words of an utterance still being
/// spoken go out as volatile text in the meantime.
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
    /// How often to preview an utterance in progress; nil for no previews.
    private let previewInterval: Duration?
    private let maximumUtteranceLength: Double
    /// Speech an utterance needs before its first preview, so a short call
    /// ("Go.") goes straight to its final line.
    static let previewMinimumSpeech = 0.5
    /// A pause this long may be about to end the utterance: its final line
    /// is close, so a preview would be wasted work.
    static let previewPauseCutoff = 0.3
    /// Whether this utterance's words in progress are on screen, so they
    /// can be cleared if no final line comes to replace them.
    private var previewOnScreen = false

    /// With `voiceChanges` set, each line goes out `.recognized` and then
    /// `.annotated` with its voice letter; `voiceprints` is the app's shared
    /// voice model (nil leaves lines without letters). `previewInterval`
    /// turns on previews of the utterance in progress, if the recognizer
    /// gives them. `maximumUtteranceLength` is in seconds; tests shorten it.
    public init(
        channelID: UUID, source: AudioSource, sessionOffset: Double, recognizer: any UtteranceRecognizer,
        voiceChanges: VoiceChangeSettings? = nil, voiceprints: (any VoiceprintExtractor)? = nil,
        previewInterval: Duration? = nil, maximumUtteranceLength: Double = 20,
        onEvent: @escaping TranscriptionHandler, onStatus: @escaping StatusHandler
    ) {
        self.channelID = channelID
        self.source = source
        self.sessionOffset = sessionOffset
        self.recognizer = recognizer
        self.previewInterval = previewInterval
        self.maximumUtteranceLength = maximumUtteranceLength
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

    public func updateVoiceSettings(_ settings: VoiceChangeSettings) async {
        await annotator?.update(settings: settings)
    }

    private func run() async {
        let converter = SampleRateConverter.whisper()
        var segmenter = UtteranceSegmenter(sampleRate: 16_000)
        segmenter.maximumLength = maximumUtteranceLength
        var lastPreview: (start: Double, at: ContinuousClock.Instant)?
        while !Task.isCancelled {
            let samples = source.ring.read(maxCount: source.ring.availableToRead)
            if !samples.isEmpty, let resampled = try? converter.convertToSamples(samples, sampleRate: source.sampleRate()) {
                for utterance in segmenter.append(resampled) {
                    await transcribe(utterance)
                }
            }
            if let previewInterval, let utterance = segmenter.inProgress,
               segmenter.speechInProgress >= Self.previewMinimumSpeech,
               segmenter.silenceInProgress < Self.previewPauseCutoff {
                let now = ContinuousClock.now
                // A new utterance (or a cut at the maximum) restarts the clock.
                let due = lastPreview.map { $0.start != utterance.startOffset || now - $0.at >= previewInterval } ?? true
                if due {
                    lastPreview = (utterance.startOffset, now)
                    await preview(utterance)
                }
            }
            try? await Task.sleep(for: pumpInterval)
        }
        if let last = segmenter.flush() {
            // The pump was cancelled to stop; a model that checks for
            // cancellation would drop this last line, so it runs in a task
            // of its own.
            await Task { await self.transcribe(last) }.value
        }
    }

    /// Sends the utterance so far as volatile text. Awaited in the pump, so
    /// it can never land after the utterance's final line.
    private func preview(_ utterance: UtteranceSegmenter.Utterance) async {
        guard let recognition = await recognizer.preview(utterance.samples) else { return }
        let text = recognition.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        onEvent(TranscriptionEvent(
            channelID: channelID, text: text, isFinal: false,
            sessionOffset: sessionOffset + utterance.startOffset, confidence: recognition.confidence
        ))
        previewOnScreen = true
    }

    /// Sends the utterance's final line. If none comes (the model heard
    /// nothing or failed), clears any words in progress left on screen.
    private func transcribe(_ utterance: UtteranceSegmenter.Utterance) async {
        let shown = previewOnScreen
        previewOnScreen = false
        let recognition = try? await recognizer.recognize(utterance.samples)
        let text = recognition?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let recognition, !text.isEmpty else {
            if shown {
                onEvent(TranscriptionEvent(
                    channelID: channelID, text: "", isFinal: false,
                    sessionOffset: sessionOffset + utterance.startOffset, confidence: nil
                ))
            }
            return
        }
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
