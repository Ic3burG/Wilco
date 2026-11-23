@preconcurrency import AVFoundation
import Foundation
import Speech
import WilcoCore

/// Transcribes a channel with Apple's on-device `SpeechAnalyzer` (macOS 26).
///
/// Streams continuously. With the "Fast, then corrected" profile it reports
/// volatile words as they are heard, replaced by a final line shortly after.
@available(macOS 26, *)
actor AppleChannelTranscriber: ChannelTranscriber {
    private let configuration: TranscriberConfiguration
    private let source: AudioSource
    private let sessionOffset: Double
    private let onEvent: TranscriptionHandler
    private let onStatus: StatusHandler
    /// Nil when the channel doesn't detect voice changes.
    private let annotator: VoiceAnnotator?
    private var voices: VoiceAnnotationQueue?
    private var clips: ChannelClips?
    /// Recent 16 kHz audio on the analyzer's timeline (seconds since the first
    /// sample fed), so a final line's audio can be found by its range. Only
    /// with voice changes or clip keeping on; filled while the voice model is
    /// usable or clips are being kept.
    private var history: AudioHistory?

    private var analyzer: SpeechAnalyzer?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var pump: Task<Void, Never>?
    private var meter: ChannelMeter?
    private var results: Task<Void, Never>?
    /// Whether any audio reached the analyzer. One that got none never ends
    /// its results when finalized, so it must be cancelled instead.
    private var receivedAudio = false

    init(
        configuration: TranscriberConfiguration, source: AudioSource, sessionOffset: Double,
        voiceprints: (any VoiceprintExtractor)?,
        onEvent: @escaping TranscriptionHandler, onStatus: @escaping StatusHandler
    ) {
        self.configuration = configuration
        self.source = source
        self.sessionOffset = sessionOffset
        self.onEvent = onEvent
        self.onStatus = onStatus
        annotator = configuration.voiceChanges.map {
            VoiceAnnotator(settings: $0, extractor: voiceprints ?? UnavailableVoiceprints())
        }
    }

    func start() async {
        onStatus(.preparing)
        do {
            try await begin()
            onStatus(.listening)
        } catch {
            onStatus(.failed(error.localizedDescription))
        }
    }

    func stop() async {
        pump?.cancel()
        await pump?.value
        meter?.finish(at: Date())
        meter = nil
        input?.finish()
        if receivedAudio {
            try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        } else {
            // Nothing to finalize, and finalizing would leave the results
            // stream open forever.
            await analyzer?.cancelAndFinishNow()
            results?.cancel()
        }
        await results?.value
        // Lines already sent to rules still get their voice.
        await voices?.finish()
        voices = nil
        history = nil
        pump = nil
        results = nil
        analyzer = nil
        input = nil
    }

    func updateVoiceSettings(_ settings: VoiceChangeSettings) async {
        await annotator?.update(settings: settings)
    }

    private func begin() async throws {
        let module = try await makeModule()
        try await SpeechAssets.install([module]) { [onStatus] in onStatus(.downloading(progress: $0)) }

        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
            throw TranscriberError("No audio format is available for this language")
        }
        let analyzer = SpeechAnalyzer(modules: [module])
        if !configuration.vocabulary.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = configuration.vocabulary
            try await analyzer.setContext(context)
        }
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        try await analyzer.start(inputSequence: stream)
        self.analyzer = analyzer
        input = continuation

        clips = source.clips.map {
            ChannelClips(
                tap: $0, channel: configuration.channelID, engine: configuration.engine.rawValue, whisperModel: nil
            )
        }
        if annotator != nil || clips != nil { history = AudioHistory() }
        if let annotator { voices = VoiceAnnotationQueue(annotator: annotator, onEvent: onEvent) }
        results = Task { await self.forwardResults(of: module) }
        _ = source.ring.read(maxCount: source.ring.availableToRead)
        meter = source.diagnostics.map {
            ChannelMeter(channelID: configuration.channelID, tap: $0, countsUtterances: false)
        }
        pump = Task { await self.feed(continuation, format: format) }
    }

    private func makeModule() async throws -> any SpeechModule {
        try await SpeechAssets.module(
            engine: configuration.engine,
            localeIdentifier: configuration.localeIdentifier,
            streaming: configuration.latencyProfile == .leadAndCorrect,
            wordTimings: annotator != nil
        )
    }

    private func feed(_ continuation: AsyncStream<AnalyzerInput>.Continuation, format: AVAudioFormat) async {
        let converter = SampleRateConverter(output: format)
        // A second resampler, to 16 kHz for voiceprints, made the first time
        // the voice model is usable.
        var voiceConverter: SampleRateConverter?
        while !Task.isCancelled {
            let samples = source.read(metering: &meter)
            if !samples.isEmpty, let buffers = try? converter.convert(samples, sampleRate: source.sampleRate()) {
                for buffer in buffers { continuation.yield(AnalyzerInput(buffer: buffer)) }
                if !buffers.isEmpty { receivedAudio = true }
                if history != nil {
                    // The history's clock moves on by what the analyzer was
                    // fed, even when this resampler fails (silence is kept
                    // instead) or nothing needs the audio (the voice model
                    // isn't usable and clips are off, so nothing is kept),
                    // so later lines still find their own audio.
                    let rate = source.sampleRate()
                    let seconds = Double(samples.count) / rate
                    if annotator?.isUsable == true || clips != nil {
                        if voiceConverter == nil { voiceConverter = SampleRateConverter.whisper() }
                        history?.append(try? voiceConverter?.convertToSamples(samples, sampleRate: rate), lasting: seconds)
                    } else {
                        history?.skip(seconds)
                    }
                }
            }
            try? await Task.sleep(for: pumpInterval)
        }
    }

    private func forwardResults(of module: any SpeechModule) async {
        do {
            if let transcriber = module as? SpeechTranscriber {
                for try await result in transcriber.results {
                    emit(text: result.text, isFinal: result.isFinal, range: result.range)
                }
            } else if let transcriber = module as? DictationTranscriber {
                for try await result in transcriber.results {
                    emit(text: result.text, isFinal: result.isFinal, range: result.range)
                }
            }
        } catch {
            onStatus(.failed(error.localizedDescription))
        }
    }

    private func emit(text: AttributedString, isFinal: Bool, range: CMTimeRange) {
        let confidences = text.runs.compactMap { $0[AttributeScopes.SpeechAttributes.ConfidenceAttribute.self] }
        // Seconds on the analyzer's timeline, which starts with the first sample fed.
        let start = range.start.isNumeric ? range.start.seconds : 0
        let end = range.duration.isNumeric ? start + range.duration.seconds : start
        let event = TranscriptionEvent(
            channelID: configuration.channelID,
            text: String(text.characters),
            isFinal: isFinal,
            sessionOffset: sessionOffset + start,
            confidence: confidences.isEmpty ? nil : confidences.reduce(0, +) / Double(confidences.count)
        )
        guard isFinal else {
            onEvent(event)
            return
        }
        deliverFinalLine(
            event, voices: voices, onEvent: onEvent,
            lineStart: sessionOffset + start, lineEnd: sessionOffset + end,
            words: annotator?.isUsable == true ? Self.words(in: text, sessionOffset: sessionOffset) : [],
            audio: { history?.samples(from: start, to: end) ?? [] },
            clips: clips
        )
    }

    /// Each word of a result with its audio time range (asked for with the
    /// `.audioTimeRange` attribute option), in session offsets. Neighbouring
    /// runs that share a range are one word; text without a range is left out.
    static func words(in text: AttributedString, sessionOffset: Double) -> [TimedWord] {
        var words: [TimedWord] = []
        var lastRange: CMTimeRange?
        for run in text.runs {
            guard let range = run[AttributeScopes.SpeechAttributes.TimeRangeAttribute.self],
                  range.start.isNumeric, range.duration.isNumeric
            else {
                lastRange = nil
                continue
            }
            let piece = String(text.characters[run.range])
            if range == lastRange, !words.isEmpty {
                words[words.count - 1].text += piece
            } else {
                let start = sessionOffset + range.start.seconds
                words.append(TimedWord(text: piece, start: start, end: start + range.duration.seconds))
            }
            lastRange = range
        }
        return words.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}

struct TranscriberError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}
