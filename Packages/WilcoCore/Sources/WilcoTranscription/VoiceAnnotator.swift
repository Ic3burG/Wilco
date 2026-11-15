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
    /// False once the voice model failed to load: lines then go out without
    /// letters rather than retrying the load on every line.
    private var available = true

    public init(settings: VoiceChangeSettings, extractor: any VoiceprintExtractor) {
        self.extractor = extractor
        tracker = VoiceTracker(settings: settings)
    }

    /// Loads the voice model ahead of the first line. A model that won't load
    /// leaves lines without letters; it never stops the channel.
    public func prepare() async {
        do {
            try await extractor.prepare()
        } catch {
            available = false
        }
    }

    /// The `.annotated` form of a recognised line. `audio` is the line's 16 kHz
    /// mono audio, which runs from `lineStart` to `lineEnd` (session offsets).
    ///
    /// For now a line stays whole and takes the letter of its longest piece.
    /// When voice analysis fails, or there is no audio, the line still comes
    /// back, with no letter; it counts towards the exchange like any line.
    public func annotate(
        _ line: TranscriptionEvent, audio: [Float], lineStart: Double, lineEnd: Double
    ) async -> [TranscriptionEvent] {
        var prints: [Voiceprint] = []
        if available, !audio.isEmpty {
            prints = (try? await extractor.voiceprints(of: audio, startingAt: lineStart)) ?? []
        }
        let pieces = tracker.assign(prints, lineStart: lineStart, lineEnd: max(lineEnd, lineStart))
        let longest = pieces.enumerated().max { a, b in
            // Ties go to the earlier piece.
            let (da, db) = (a.element.end - a.element.start, b.element.end - b.element.start)
            return da != db ? da < db : a.offset > b.offset
        }?.element
        var annotated = line
        annotated.isFinal = true
        annotated.stage = .annotated(voice: longest?.voice, exchange: longest?.exchange)
        return [annotated]
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
                    job.line, audio: job.audio, lineStart: job.lineStart, lineEnd: job.lineEnd
                )
                if !job.audio.isEmpty { pending.count.withLock { $0.now -= 1 } }
                for event in events { onEvent(event) }
            }
        }
    }

    /// Queues a recognised line for annotation. `audio` is only fetched when
    /// there is room for it.
    func submit(_ line: TranscriptionEvent, audio: () -> [Float], lineStart: Double, lineEnd: Double) {
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
        jobs.yield(Job(line: line, audio: samples, lineStart: lineStart, lineEnd: lineEnd))
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
/// fetched in that case.
func deliverFinalLine(
    _ line: TranscriptionEvent, voices: VoiceAnnotationQueue?, onEvent: TranscriptionHandler,
    lineStart: Double, lineEnd: Double, audio: () -> [Float]
) {
    guard let voices, !line.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        onEvent(line)
        return
    }
    var recognised = line
    recognised.stage = .recognized
    onEvent(recognised)
    voices.submit(recognised, audio: audio, lineStart: lineStart, lineEnd: lineEnd)
}

/// Stands in when voice changes are on but no voice model was given: every
/// line goes out without a letter.
struct UnavailableVoiceprints: VoiceprintExtractor {
    func prepare() async throws { throw VoiceprintError.notInstalled }
    func voiceprints(of samples: [Float], startingAt offset: Double) async throws -> [Voiceprint] {
        throw VoiceprintError.notInstalled
    }
}
