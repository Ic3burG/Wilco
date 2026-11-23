import Foundation
import Observation
import WilcoCore
import WilcoTranscription

/// Labels kept clips in the background once a show is over. The rule for
/// when it may run is `LearningSchedule`; this only does the work, and stops
/// the moment capture starts.
@MainActor
@Observable
final class LearningController {
    /// "Labelling clips: 40 of 120" while working, nil otherwise.
    private(set) var status: String?

    @ObservationIgnored private let isCapturing: @MainActor () -> Bool
    @ObservationIgnored private let lastCaptureStop: @MainActor () -> Date?
    @ObservationIgnored private let ultra: ParakeetModelStore
    @ObservationIgnored private let whisper: WhisperModelStore
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var tick: Timer?
    @ObservationIgnored private var afterStop: Timer?
    /// Sessions that failed this run, so a broken file isn't retried every minute.
    @ObservationIgnored private var skipped: Set<URL> = []

    init(
        ultra: ParakeetModelStore, whisper: WhisperModelStore,
        isCapturing: @escaping @MainActor () -> Bool, lastCaptureStop: @escaping @MainActor () -> Date?
    ) {
        self.ultra = ultra
        self.whisper = whisper
        self.isCapturing = isCapturing
        self.lastCaptureStop = lastCaptureStop
    }

    /// Checks now and every minute from here on.
    func start() {
        tick = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        check()
    }

    /// Starts labelling if it is allowed, there is something to label and
    /// enough models are installed.
    func check() {
        guard task == nil,
              LearningSchedule.mayRun(now: .now, capturing: isCapturing(), lastCaptureStop: lastCaptureStop())
        else { return }
        let ultra = ultra, whisper = whisper, skipped = skipped
        task = Task.detached(priority: .background) { [weak self] in
            // Models may have been installed since the last check.
            let voters = await ClipVoters.installed(ultra: ultra, whisper: whisper)
            let diarizers = Self.installedDiarizers()
            if voters.count >= 2, !Task.isCancelled {
                let labeller = ClipLabeller(voters: voters, diarizers: diarizers)
                let sessions = ClipsFolder.needingLabels(in: DataLocations.transcripts, voters: labeller.voterVersions)
                    .filter { !skipped.contains($0) }
                for transcript in sessions {
                    if Task.isCancelled { break }
                    do {
                        try await Self.label(transcript, with: labeller) { done, total in
                            Task { @MainActor in self?.status = "Labelling clips: \(done) of \(total)" }
                        }
                    } catch is CancellationError {
                        break
                    } catch {
                        await self?.skip(transcript)
                    }
                }
            }
            await self?.finished()
        }
    }

    /// Capture is starting: stop at once. Labels made so far are already saved.
    func captureStarted() {
        task?.cancel()
        afterStop?.invalidate()
        afterStop = nil
    }

    /// Capture stopped: look again once the wait is over.
    func captureStopped() {
        afterStop?.invalidate()
        afterStop = Timer.scheduledTimer(withTimeInterval: LearningSchedule.delayAfterCapture, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
    }

    private func skip(_ url: URL) { skipped.insert(url) }

    private func finished() {
        task = nil
        status = nil
    }

    nonisolated private static func installedDiarizers() -> [any ClipDiarizer] {
        let all: [any ClipDiarizer] = [PipelineClipDiarizer(), SortformerClipDiarizer()]
        return all.filter { $0.isInstalled() }
    }

    nonisolated private static func label(
        _ transcript: URL, with labeller: ClipLabeller, progress: @escaping @Sendable (Int, Int) -> Void
    ) async throws {
        let show = SessionShow.load(forTranscript: transcript) ?? bestMatch(for: transcript)
        try await labeller.label(transcript: transcript, show: show, progress: progress)
    }

    nonisolated private static func bestMatch(for transcript: URL) -> ShowDocument? {
        guard let data = try? Data(contentsOf: transcript) else { return nil }
        let store = ConfigurationStore()
        let shows = store.list().compactMap { try? store.document($0.id) }
        return SessionShow.bestMatch(for: TranscriptFile.segments(in: data), among: shows)
    }
}
