import Foundation
import Observation
import WilcoCore
import WilcoTranscription

/// Downloads and removes speech models from Settings. It lives as long as
/// the app, so a download carries on if the Settings window is closed.
@MainActor
@Observable
final class ModelInstaller {
    /// One speech model: Whisper's are named by size, Apple's by engine and language.
    enum Item: Hashable {
        case whisper(WhisperModel)
        /// Parakeet is one model for every channel, plus its vocabulary model.
        case parakeet
        /// Parakeet Ultra, which only transcribes kept clips after a show.
        case parakeetUltra
        case apple(SpeechEngine, localeIdentifier: String)
        /// The speaker-embedding model that tells voices apart; shared by every channel.
        case voiceModel
    }

    /// Progress from 0 to 1 for each download in flight.
    private(set) var progress: [Item: Double] = [:]
    private(set) var errors: [Item: String] = [:]
    /// Changes whenever something was installed or removed, so views re-check.
    private(set) var generation = 0
    /// Called after a download finishes, so running channels that were
    /// waiting on a model can pick it up.
    @ObservationIgnored var onInstalled: (@MainActor () -> Void)?

    let whisperStore = WhisperModelStore()
    let parakeetStore: ParakeetModelStore
    let parakeetUltraStore: ParakeetModelStore
    let voiceprints: WeSpeakerVoiceprints
    /// Whether the voice model is on disk. Kept here so the transcript and
    /// inspector, which can't poll, update the moment it's installed or removed.
    private(set) var voiceModelInstalled: Bool

    init(parakeetStore: ParakeetModelStore, parakeetUltraStore: ParakeetModelStore, voiceprints: WeSpeakerVoiceprints) {
        self.parakeetStore = parakeetStore
        self.parakeetUltraStore = parakeetUltraStore
        self.voiceprints = voiceprints
        voiceModelInstalled = voiceprints.isInstalled()
    }

    /// Re-reads the disk, for a model removed or added behind the app's back.
    func setVoiceModelInstalled(_ installed: Bool) {
        if voiceModelInstalled != installed { voiceModelInstalled = installed }
    }

    func isBusy(_ item: Item) -> Bool { progress[item] != nil }

    func install(_ item: Item) {
        guard progress[item] == nil else { return }
        progress[item] = 0
        errors[item] = nil
        let report: @Sendable (Double) -> Void = { [weak self] fraction in
            Task { @MainActor in
                // A late report must not resurrect a finished download.
                if self?.progress[item] != nil { self?.progress[item] = fraction }
            }
        }
        Task {
            do {
                switch item {
                case .whisper(let model):
                    try await whisperStore.download(model, progress: report)
                case .parakeet:
                    try await parakeetStore.install(progress: report)
                case .parakeetUltra:
                    try await parakeetUltraStore.install(progress: report)
                case .apple(let engine, let locale):
                    try await SpeechAssets.install(engine: engine, localeIdentifier: locale, progress: report)
                case .voiceModel:
                    try await voiceprints.install(progress: report)
                }
            } catch {
                errors[item] = error.localizedDescription
            }
            progress[item] = nil
            voiceModelInstalled = voiceprints.isInstalled()
            generation += 1
            if errors[item] == nil { onInstalled?() }
        }
    }

    func remove(_ item: Item) {
        errors[item] = nil
        switch item {
        case .whisper(let model):
            do { try whisperStore.remove(model) } catch { errors[item] = error.localizedDescription }
            generation += 1
        case .parakeet:
            do { try parakeetStore.remove() } catch { errors[item] = error.localizedDescription }
            generation += 1
        case .parakeetUltra:
            do { try parakeetUltraStore.remove() } catch { errors[item] = error.localizedDescription }
            generation += 1
        case .voiceModel:
            do { try voiceprints.remove() } catch { errors[item] = error.localizedDescription }
            voiceModelInstalled = voiceprints.isInstalled()
            generation += 1
        case .apple(_, let locale):
            Task {
                await SpeechAssets.release(localeIdentifier: locale)
                generation += 1
            }
        }
    }
}
