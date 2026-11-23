import AVFoundation
import FluidAudio
import Foundation
import Speech
import WilcoCore

/// A strong local model that transcribes kept clips after a show, so the
/// voters' texts can be compared. Clips are 16 kHz mono.
public protocol ClipVoter: Sendable {
    /// One of `ClipVoterID`.
    var id: String { get }
    /// Goes into a clip's labels; a change means its clips are labelled again.
    var version: String { get }
    func isInstalled() -> Bool
    func transcribe(_ samples: [Float], vocabulary: [String], localeIdentifier: String) async throws -> String
}

/// Parakeet Ultra, kept in its own folder and sharing the live Parakeet's
/// vocabulary model.
public struct ParakeetUltraVoter: ClipVoter {
    public let store: ParakeetModelStore
    public var id: String { ClipVoterID.parakeetUltra }
    public var version: String { AsrModels.defaultCacheDirectory(for: .ultra).lastPathComponent }

    public init(store: ParakeetModelStore) {
        self.store = store
    }

    public func isInstalled() -> Bool { store.isInstalled() }

    public func transcribe(_ samples: [Float], vocabulary: [String], localeIdentifier: String) async throws -> String {
        let recognizer = ParakeetRecognizer(
            store: store, language: ParakeetLanguages.language(for: localeIdentifier), vocabulary: vocabulary
        )
        return try await recognizer.recognize(samples)?.text ?? ""
    }
}

/// Whisper large-v3, when it has been downloaded.
public struct WhisperLargeVoter: ClipVoter {
    public let store: WhisperModelStore
    public var id: String { ClipVoterID.whisperLarge }
    public var version: String { WhisperModel.large.variant }

    public init(store: WhisperModelStore) {
        self.store = store
    }

    public func isInstalled() -> Bool { store.isDownloaded(.large) }

    public func transcribe(_ samples: [Float], vocabulary: [String], localeIdentifier: String) async throws -> String {
        // No language means Whisper detects it, as on a live channel.
        let language = localeIdentifier.isEmpty
            ? nil
            : Locale(identifier: localeIdentifier).language.languageCode?.identifier
        let results = try await store.transcribe(
            samples, model: .large, language: language, vocabulary: vocabulary, translate: false
        )
        return results.flatMap(\.segments).map(\.text).joined().trimmingCharacters(in: .whitespaces)
    }
}

/// Apple's long-form speech model, run once over the whole clip.
@available(macOS 26, *)
public struct AppleLongFormVoter: ClipVoter {
    /// Whether the model's assets were installed when the voter was made;
    /// checking needs `await`, so ``ClipVoters/installed(ultra:whisper:)``
    /// asks first.
    private let installed: Bool
    public var id: String { ClipVoterID.appleLongForm }
    /// The model comes with macOS, so its version is the system's.
    public var version: String { ProcessInfo.processInfo.operatingSystemVersionString }

    public init(installed: Bool) {
        self.installed = installed
    }

    /// A voter for the locale whose assets decide whether it votes.
    public static func checking(localeIdentifier: String) async -> AppleLongFormVoter {
        AppleLongFormVoter(
            installed: await SpeechAssets.status(engine: .longForm, localeIdentifier: localeIdentifier) == .installed
        )
    }

    public func isInstalled() -> Bool { installed }

    public func transcribe(_ samples: [Float], vocabulary: [String], localeIdentifier: String) async throws -> String {
        let module = try await SpeechAssets.module(
            engine: .longForm, localeIdentifier: localeIdentifier, streaming: false, wordTimings: false
        )
        guard let transcriber = module as? SpeechTranscriber else {
            throw TranscriberError("Long-form speech is not available")
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw TranscriberError("No audio format is available for this language")
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        if !vocabulary.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = vocabulary
            try await analyzer.setContext(context)
        }
        let buffers = try SampleRateConverter(output: format).convert(samples, sampleRate: 16_000)
        // An analyzer that is fed no audio never ends its results, so an
        // empty clip would wait forever.
        guard !buffers.isEmpty else { return "" }

        // Read results while the analyzer runs; the sequence ends when it finishes.
        let collected = Task {
            var lines: [String] = []
            for try await result in transcriber.results where result.isFinal {
                lines.append(String(result.text.characters))
            }
            return lines
        }
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        do {
            try await analyzer.start(inputSequence: stream)
            for buffer in buffers { continuation.yield(AnalyzerInput(buffer: buffer)) }
            continuation.finish()
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            continuation.finish()
            await analyzer.cancelAndFinishNow()
            collected.cancel()
            throw error
        }
        let lines = try await collected.value
        return lines.map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

public enum ClipVoters {
    /// The voters ready on this Mac, in preference order: Parakeet Ultra,
    /// Apple long-form (macOS 26 and later, when its English assets are
    /// installed), Whisper large-v3.
    public static func installed(ultra: ParakeetModelStore, whisper: WhisperModelStore) async -> [any ClipVoter] {
        var voters: [any ClipVoter] = []
        let ultraVoter = ParakeetUltraVoter(store: ultra)
        if ultraVoter.isInstalled() { voters.append(ultraVoter) }
        if #available(macOS 26, *) {
            let apple = await AppleLongFormVoter.checking(localeIdentifier: "en-US")
            if apple.isInstalled() { voters.append(apple) }
        }
        let whisperVoter = WhisperLargeVoter(store: whisper)
        if whisperVoter.isInstalled() { voters.append(whisperVoter) }
        return voters
    }
}
