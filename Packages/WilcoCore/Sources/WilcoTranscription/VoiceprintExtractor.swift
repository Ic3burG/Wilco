import FluidAudio
import Foundation
import WilcoCore

/// Turns a stretch of speech into voiceprints, one per short window.
public protocol VoiceprintExtractor: Sendable {
    /// Loads the model ahead of the first line.
    func prepare() async throws
    /// Voiceprints for 16 kHz mono `samples`, which start `offset` seconds
    /// into the session: windows of 1.5 s every 0.5 s, sorted by start.
    /// Audio shorter than 0.5 s gives none.
    func voiceprints(of samples: [Float], startingAt offset: Double) async throws -> [Voiceprint]
}

public enum VoiceprintError: Error, Equatable, LocalizedError {
    case notInstalled

    public var errorDescription: String? {
        switch self {
        case .notInstalled:
            "The voice model isn't installed. Install it in Settings."
        }
    }
}

/// The WeSpeaker speaker-embedding model (pyannote Community-1, as converted
/// for FluidAudio), loaded once for every channel. Prints stay in memory: this
/// type never writes, logs or keeps them.
public actor WeSpeakerVoiceprints: VoiceprintExtractor {
    static let sampleRate = 16_000
    /// Each print covers this much audio, taken every `hop`.
    static let windowLength = sampleRate * 3 / 2
    static let hop = sampleRate / 2
    /// Less audio than this gives no print.
    static let minimumLength = sampleRate / 2

    private let directory: URL
    private var loaded: EmbeddingPipeline?
    /// A load in progress, so channels starting together load the model once.
    private var loading: Task<EmbeddingPipeline, Error>?

    public init(directory: URL = DataLocations.voiceModels) {
        self.directory = directory
    }

    /// FluidAudio keeps the diarizer repository in a folder named for it.
    private nonisolated var repoFolder: URL {
        directory.appending(path: Repo.diarizer.folderName, directoryHint: .isDirectory)
    }

    /// Whether every file the embedding pipeline loads is on disk. The
    /// repository's offline set also holds a segmentation model and PLDA
    /// files: FluidAudio's loader insists on them, so they're fetched too.
    public nonisolated func isInstalled() -> Bool {
        let files = FileManager.default
        return ModelNames.OfflineDiarizer.requiredModels.allSatisfy { name in
            let path = repoFolder.appending(path: name)
            if name.hasSuffix(".mlmodelc") {
                return files.fileExists(atPath: path.appending(path: "coremldata.bin").path)
            }
            return files.fileExists(atPath: path.path)
        }
    }

    /// Downloads the model, reporting progress from 0 to 1. Files already on
    /// disk aren't fetched again.
    public nonisolated func install(progress: @escaping @Sendable (Double) -> Void) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try await ModelHub.download(.diarizer, to: directory, variant: "offline") { progress($0.fractionCompleted) }
        progress(1)
    }

    /// Deletes the downloaded model. Don't remove it while channels use it.
    public nonisolated func remove() throws {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.removeItem(at: directory)
    }

    public func prepare() async throws {
        _ = try await pipeline()
    }

    public func voiceprints(of samples: [Float], startingAt offset: Double) async throws -> [Voiceprint] {
        let windows = Self.windows(sampleCount: samples.count)
        guard !windows.isEmpty else { return [] }
        let pipeline = try await pipeline()
        let rate = Double(Self.sampleRate)
        let spans = windows.map { Double($0.lowerBound) / rate..<Double($0.upperBound) / rate }
        let vectors = try await pipeline.embed(samples, spans: spans)
        return zip(spans, vectors).compactMap { span, vector in
            guard let unit = Self.normalised(vector) else { return nil }
            return Voiceprint(vector: unit, start: offset + span.lowerBound, end: offset + span.upperBound)
        }
    }

    /// Sample ranges to take prints from: 1.5 s windows every 0.5 s, plus one
    /// ending with the audio when the hop leaves its end uncovered. Audio
    /// shorter than a window but at least 0.5 s long is one window.
    static func windows(sampleCount: Int) -> [Range<Int>] {
        guard sampleCount >= minimumLength else { return [] }
        guard sampleCount > windowLength else { return [0..<sampleCount] }
        var out: [Range<Int>] = []
        var start = 0
        while start + windowLength <= sampleCount {
            out.append(start..<(start + windowLength))
            start += hop
        }
        if let last = out.last, last.upperBound < sampleCount {
            out.append((sampleCount - windowLength)..<sampleCount)
        }
        return out
    }

    private static func normalised(_ v: [Float]) -> [Float]? {
        var sq: Float = 0
        for x in v { sq += x * x }
        guard !v.isEmpty, sq.isFinite, sq > 1e-12 else { return nil }
        let inv = 1 / sq.squareRoot()
        return v.map { $0 * inv }
    }

    // MARK: - Loading

    /// FluidAudio's span embedder: FBank features, then the WeSpeaker model
    /// on each window repeated to fill its 10 s input, up to 32 windows per
    /// prediction. The manager is written only while loading; after that
    /// FluidAudio runs `embedSpans` calls one at a time on an actor of its
    /// own, so sharing one pipeline between channels is safe.
    private final class EmbeddingPipeline: @unchecked Sendable {
        private let manager: OfflineDiarizerManager

        init(models: OfflineDiarizerModels) {
            manager = OfflineDiarizerManager()
            manager.initialize(models: models)
        }

        /// Raw (not normalised) embeddings, one per span, in order.
        func embed(_ samples: [Float], spans: [Range<Double>]) async throws -> [[Float]] {
            try await manager.embedSpans(audioSource: ArrayAudioSampleSource(samples: samples), spans: spans)
        }
    }

    /// The loaded embedding pipeline, shared by every channel.
    private func pipeline() async throws -> EmbeddingPipeline {
        // Checked before the cache so a removed model stops being served.
        guard isInstalled() else {
            loaded = nil
            throw VoiceprintError.notInstalled
        }
        if let loaded { return loaded }
        let folder = directory
        let task: Task<EmbeddingPipeline, Error>
        if let loading {
            task = loading
        } else {
            task = Task {
                let pipeline = EmbeddingPipeline(models: try await OfflineDiarizerModels.load(from: folder))
                // The first prediction compiles for the Neural Engine; do it now
                // rather than on a channel's first line.
                let warmup = (0..<Self.sampleRate).map { Float(($0 * 7_919) % 200 - 100) / 10_000 }
                _ = try await pipeline.embed(warmup, spans: [0..<1])
                return pipeline
            }
            loading = task
        }
        do {
            let pipeline = try await task.value
            loaded = pipeline
            if loading == task { loading = nil }
            return pipeline
        } catch {
            // A later load may have replaced this one; leave it alone.
            if loading == task { loading = nil }
            throw error
        }
    }
}
