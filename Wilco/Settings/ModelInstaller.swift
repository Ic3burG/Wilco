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
        case apple(SpeechEngine, localeIdentifier: String)
    }

    /// Progress from 0 to 1 for each download in flight.
    private(set) var progress: [Item: Double] = [:]
    private(set) var errors: [Item: String] = [:]
    /// Changes whenever something was installed or removed, so views re-check.
    private(set) var generation = 0

    let whisperStore = WhisperModelStore()

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
                case .apple(let engine, let locale):
                    try await SpeechAssets.install(engine: engine, localeIdentifier: locale, progress: report)
                }
            } catch {
                errors[item] = error.localizedDescription
            }
            progress[item] = nil
            generation += 1
        }
    }

    func remove(_ item: Item) {
        errors[item] = nil
        switch item {
        case .whisper(let model):
            do { try whisperStore.remove(model) } catch { errors[item] = error.localizedDescription }
            generation += 1
        case .apple(_, let locale):
            Task {
                await SpeechAssets.release(localeIdentifier: locale)
                generation += 1
            }
        }
    }
}
