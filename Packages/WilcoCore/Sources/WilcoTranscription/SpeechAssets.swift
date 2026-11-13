import Foundation
import Speech
import WilcoCore

/// Whether a speech model is on this Mac.
public enum SpeechAssetStatus: Equatable, Sendable {
    case installed
    case notInstalled
    /// The system is fetching it (possibly for another app).
    case downloading
    /// This engine can't transcribe this language, or needs a newer macOS.
    case unavailable
}

/// Apple's on-device speech models, which macOS downloads and keeps per
/// language. Whisper's models are managed by ``WhisperModelStore``.
public enum SpeechAssets {
    /// An empty identifier means "detect automatically", which only Whisper
    /// offers, so Apple's engines use this Mac's language instead.
    public static func locale(for identifier: String) -> Locale {
        identifier.isEmpty ? Locale.current : Locale(identifier: identifier)
    }

    public static func status(engine: SpeechEngine, localeIdentifier: String) async -> SpeechAssetStatus {
        guard engine != .whisper, #available(macOS 26, *) else { return .unavailable }
        guard let module = try? await module(engine: engine, localeIdentifier: localeIdentifier, streaming: false) else {
            return .unavailable
        }
        switch await AssetInventory.status(forModules: [module]) {
        case .installed: return .installed
        case .downloading: return .downloading
        case .supported: return .notInstalled
        default: return .unavailable
        }
    }

    /// Downloads and installs the model, reporting progress from 0 to 1.
    public static func install(
        engine: SpeechEngine, localeIdentifier: String, progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        guard engine != .whisper, #available(macOS 26, *) else { return }
        let module = try await module(engine: engine, localeIdentifier: localeIdentifier, streaming: false)
        try await install([module], progress: progress)
    }

    /// Long-form languages Wilco has asked macOS to keep.
    public static func reservedLocaleIdentifiers() async -> [String] {
        guard #available(macOS 26, *) else { return [] }
        return await AssetInventory.reservedLocales.map(\.identifier)
    }

    /// Tells macOS Wilco no longer needs a language. The system removes the
    /// model when no other app is using it, so it may not vanish at once.
    public static func release(localeIdentifier: String) async {
        guard #available(macOS 26, *) else { return }
        _ = await AssetInventory.release(reservedLocale: Locale(identifier: localeIdentifier))
    }

    @available(macOS 26, *)
    static func install(_ modules: [any SpeechModule], progress: @escaping @Sendable (Double) -> Void) async throws {
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: modules) else { return }
        progress(0)
        let tracked = request.progress
        let watcher = Task {
            while !Task.isCancelled {
                progress(tracked.fractionCompleted)
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        defer { watcher.cancel() }
        try await request.downloadAndInstall()
    }

    @available(macOS 26, *)
    static func module(engine: SpeechEngine, localeIdentifier: String, streaming: Bool) async throws -> any SpeechModule {
        let locale = locale(for: localeIdentifier)
        switch engine {
        case .dictation:
            guard let supported = await DictationTranscriber.supportedLocale(equivalentTo: locale) else {
                throw TranscriberError("Dictation does not support \(locale.identifier)")
            }
            return DictationTranscriber(
                locale: supported,
                contentHints: [.shortForm],
                transcriptionOptions: [.punctuation],
                reportingOptions: streaming ? [.volatileResults, .frequentFinalization] : [.frequentFinalization],
                attributeOptions: [.transcriptionConfidence]
            )
        case .longForm, .whisper:
            guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
                throw TranscriberError("Long-form speech does not support \(locale.identifier)")
            }
            return SpeechTranscriber(
                locale: supported,
                transcriptionOptions: [],
                reportingOptions: streaming ? [.volatileResults, .fastResults] : [],
                attributeOptions: [.transcriptionConfidence]
            )
        }
    }
}
