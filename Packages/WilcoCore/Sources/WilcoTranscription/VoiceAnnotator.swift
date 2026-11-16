import Foundation
import Synchronization
import WilcoCore

/// Gives a channel's final lines their voice letters: voiceprints from the
/// line's audio, matched against the voices of the current exchange.
///
/// One per channel run, so a restarted channel starts a fresh exchange. Call
/// `annotate` one line at a time, in line order (``VoiceAnnotationQueue``
/// does): the exchange's voices depend on the order lines arrive.
public actor VoiceAnnotator {
    private let extractor: any VoiceprintExtractor
    private var tracker: VoiceTracker
    /// False while the voice model isn't usable: lines then go out without
    /// letters, and loading is retried at most once per `retryInterval`
    /// (a model installed mid-run is picked up; one removed mid-run is let go).
    private var available = true
    private var lastAttempt: Double?
    private let now: @Sendable () -> Double

    /// The least time between attempts to load a model that wasn't usable.
    public static let retryInterval = 5.0

    /// `now` gives seconds from any steady clock; tests pass their own.
    public init(
        settings: VoiceChangeSettings, extractor: any VoiceprintExtractor,
        now: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.extractor = extractor
        self.now = now
        tracker = VoiceTracker(settings: settings)
    }

    /// Loads the voice model ahead of the first line. A model that won't load
    /// leaves lines without letters; it never stops the channel.
    public func prepare() async {
        do {
            try await extractor.prepare()
            available = true
        } catch {
            available = false
        }
        // Timed from when the attempt ended, so a slow failing load still
        // leaves a full interval before the next one.
        lastAttempt = now()
    }

    /// The `.annotated` form of a recognised line. `audio` is the line's 16 kHz
    /// mono audio, which runs from `lineStart` to `lineEnd` (session offsets).
    ///
    /// With `words` (the line's words, in session offsets), a line whose voice
    /// changes partway comes back as several pieces, cut between words, each
    /// with its own letter and offset, all sharing the line's `lineID`, in
    /// order. Only pieces that are shown get letters or become voices.
    /// Without words (or with words its text doesn't hold) the line stays
    /// whole and all its audio counts as one voice. When voice analysis fails, or there is no audio, the
    /// line still comes back, with no letter; it counts towards the exchange
    /// like any line.
    public func annotate(
        _ line: TranscriptionEvent, audio: [Float], lineStart: Double, lineEnd: Double, words: [TimedWord] = []
    ) async -> [TranscriptionEvent] {
        var prints: [Voiceprint] = []
        if !available, let last = lastAttempt, now() - last >= Self.retryInterval {
            await prepare()
        }
        if available, !audio.isEmpty {
            do {
                prints = try await extractor.voiceprints(of: audio, startingAt: lineStart)
            } catch {
                // Most likely the model was removed: stop trying until the next retry.
                available = false
                lastAttempt = now()
            }
        }
        // The tracker sees the same words the splitter cuts at, so it only
        // gives letters to pieces that will be shown.
        let placeable = LineSplitter.placeableWords(words, in: line.text)
        let pieces = tracker.assign(prints, lineStart: lineStart, lineEnd: max(lineEnd, lineStart), words: placeable)
        return LineSplitter.split(words: placeable, text: line.text, pieces: pieces).enumerated().map { i, part in
            var annotated = line
            annotated.isFinal = true
            annotated.text = part.text
            // The first piece keeps the line's own offset.
            if i > 0 { annotated.sessionOffset = part.start }
            annotated.stage = .annotated(voice: part.voice, exchange: part.exchange)
            return annotated
        }
    }
}

/// A channel's voice stage: annotates recognised lines one at a time, in the
/// order they were submitted, off the transcriber's reading loop. Voice
/// analysis can be slow (one model serves every channel), so the transcriber
/// hands each line over and carries on recognising the next.
///
/// Bounded: at most `maximumPending` lines wait with their audio. A line
/// arriving when that many are waiting is still annotated in its turn, but
/// without its audio, so it gets no letter. That keeps memory and delay in
/// check when analysis falls behind for a long show.
final class VoiceAnnotationQueue: Sendable {
    /// Lines (with their audio) allowed to wait for analysis, per channel,
    /// counting the one being analysed.
    static let maximumPending = 8

    private struct Job: Sendable {
        var line: TranscriptionEvent
        /// Empty for a line that arrived when the queue was full.
        var audio: [Float]
        var lineStart: Double
        var lineEnd: Double
        var words: [TimedWord]
    }

    private let jobs: AsyncStream<Job>.Continuation
    private let worker: Task<Void, Never>
    /// Lines waiting with audio, and the most there have been at once.
    private final class Pending: Sendable {
        let count = Mutex((now: 0, most: 0))
    }
    private let pending = Pending()

    init(annotator: VoiceAnnotator, onEvent: @escaping TranscriptionHandler) {
        let (stream, continuation) = AsyncStream<Job>.makeStream()
        jobs = continuation
        let pending = pending
        worker = Task {
            await annotator.prepare()
            for await job in stream {
                let events = await annotator.annotate(
                    job.line, audio: job.audio, lineStart: job.lineStart, lineEnd: job.lineEnd, words: job.words
                )
                if !job.audio.isEmpty { pending.count.withLock { $0.now -= 1 } }
                for event in events { onEvent(event) }
            }
        }
    }

    /// Queues a recognised line for annotation. `audio` is only fetched when
    /// there is room for it.
    func submit(
        _ line: TranscriptionEvent, audio: () -> [Float], lineStart: Double, lineEnd: Double, words: [TimedWord] = []
    ) {
        let admitted = pending.count.withLock { p in
            guard p.now < Self.maximumPending else { return false }
            p.now += 1
            p.most = max(p.most, p.now)
            return true
        }
        let samples = admitted ? audio() : []
        if admitted && samples.isEmpty {
            // Nothing to hold, so it doesn't take a place.
            pending.count.withLock { $0.now -= 1 }
        }
        jobs.yield(Job(line: line, audio: samples, lineStart: lineStart, lineEnd: lineEnd, words: words))
    }

    /// The most lines that have waited with their audio at once.
    var mostPending: Int { pending.count.withLock { $0.most } }

    /// Annotates every line already submitted, then stops. Nothing recognised
    /// is left without its annotation.
    func finish() async {
        jobs.finish()
        await worker.value
    }
}

/// Sends a final line. With voice changes off it goes out whole, exactly as
/// before. With them on, it goes to rules at once as `.recognized`, and its
/// annotated form follows from the channel's voice queue; `audio` is only
/// fetched in that case. `words` (session offsets) let the annotation split
/// the line where the voice changes.
func deliverFinalLine(
    _ line: TranscriptionEvent, voices: VoiceAnnotationQueue?, onEvent: TranscriptionHandler,
    lineStart: Double, lineEnd: Double, words: [TimedWord] = [], audio: () -> [Float]
) {
    guard let voices, !line.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        onEvent(line)
        return
    }
    var recognised = line
    recognised.stage = .recognized
    onEvent(recognised)
    voices.submit(recognised, audio: audio, lineStart: lineStart, lineEnd: lineEnd, words: words)
}

/// Stands in when voice changes are on but no voice model was given: every
/// line goes out without a letter.
struct UnavailableVoiceprints: VoiceprintExtractor {
    func prepare() async throws { throw VoiceprintError.notInstalled }
    func voiceprints(of samples: [Float], startingAt offset: Double) async throws -> [Voiceprint] {
        throw VoiceprintError.notInstalled
    }
}
