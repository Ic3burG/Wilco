@preconcurrency import CoreML
import FluidAudio
import Foundation
import WilcoCore

/// A speaker-grouping model run after a show over one channel's kept clips,
/// joined into one recording (see ``VoiceAgreement/layout(durations:gap:)``).
/// Samples are 16 kHz mono.
public protocol ClipDiarizer: Sendable {
    /// One of `ClipDiarizerID`.
    var id: String { get }
    func isInstalled() -> Bool
    /// Who speaks when, in seconds from the start of `samples`.
    func spans(of samples: [Float]) async throws -> [SpeakerSpan]
}

public enum ClipDiarizerError: Error, Equatable, LocalizedError {
    case notInstalled
    case unreadableModel(String)

    public var errorDescription: String? {
        switch self {
        case .notInstalled:
            "The voice grouping model isn't installed. Install it in Settings."
        case .unreadableModel(let file):
            "The voice grouping model file \(file) couldn't be read. Remove the model and download it again."
        }
    }
}

// MARK: - Offline pipeline

/// Segmentation, WeSpeaker embeddings and VBx clustering over the whole
/// recording. It uses the voice model the live voice tracker downloads
/// (``WeSpeakerVoiceprints``), so it needs no download of its own.
public struct PipelineClipDiarizer: ClipDiarizer {
    public var id: String { ClipDiarizerID.pipeline }
    private let voiceModel: WeSpeakerVoiceprints
    private let directory: URL
    private let cache = LoadedOnce<OfflineDiarizerModels>()

    public init(directory: URL = DataLocations.voiceModels) {
        self.directory = directory
        voiceModel = WeSpeakerVoiceprints(directory: directory)
    }

    public func isInstalled() -> Bool { voiceModel.isInstalled() }

    public func spans(of samples: [Float]) async throws -> [SpeakerSpan] {
        guard isInstalled() else {
            await cache.reset()
            throw ClipDiarizerError.notInstalled
        }
        guard !samples.isEmpty else { return [] }
        let folder = directory.appending(path: Repo.diarizer.folderName, directoryHint: .isDirectory)
        let models = try await cache.get { try Self.loadModels(from: folder) }
        // A fresh manager per call: the models are shared read-only, and the
        // manager's own state is only written while it's set up.
        let manager = OfflineDiarizerManager()
        manager.initialize(models: models)
        let result = try await manager.process(audio: samples)
        return result.segments.map {
            SpeakerSpan(speaker: $0.speakerId, start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds))
        }
    }

    /// Loads the models straight from the folder. A failed load throws and
    /// leaves the files alone, rather than deleting and fetching them again.
    static func loadModels(from folder: URL) throws -> OfflineDiarizerModels {
        let started = Date()
        func model(_ file: String, _ units: MLComputeUnits) throws -> MLModel {
            let configuration = MLModelConfiguration()
            configuration.computeUnits = units
            return try MLModel(contentsOf: folder.appending(path: file), configuration: configuration)
        }
        let names = ModelNames.OfflineDiarizer.self
        let segmentation = try model(names.segmentationPath, .all)
        let embedding = try model(names.embeddingPath, .all)
        let plda = try model(names.pldaRhoPath, .all)
        // The feature extractor runs faster on the CPU.
        let fbank = try model(names.fbankPath, .cpuOnly)
        return OfflineDiarizerModels(
            segmentationModel: segmentation,
            fbankModel: fbank,
            embeddingModel: embedding,
            pldaRhoModel: plda,
            pldaPsi: try pldaPsi(from: folder.appending(path: names.pldaParameters)),
            compilationDuration: Date().timeIntervalSince(started)
        )
    }

    /// The PLDA scaling vector: 32-bit floats, base64 in
    /// `tensors.psi.data_base64`.
    static func pldaPsi(from file: URL) throws -> [Double] {
        let bad = ClipDiarizerError.unreadableModel(file.lastPathComponent)
        guard let root = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any],
              let tensors = root["tensors"] as? [String: Any],
              let psi = tensors["psi"] as? [String: Any],
              let base64 = psi["data_base64"] as? String,
              let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters),
              data.count >= MemoryLayout<Float>.size
        else { throw bad }
        let count = data.count / MemoryLayout<Float>.size
        var floats = [Float](repeating: 0, count: count)
        _ = floats.withUnsafeMutableBytes { data.copyBytes(to: $0) }
        return floats.map(Double.init)
    }
}

// MARK: - Offline Sortformer

/// Sortformer run over the whole recording in overlapping 30 s windows: a
/// different kind of model from the pipeline, so the two make different
/// mistakes. It tells apart up to four voices.
public struct SortformerClipDiarizer: ClipDiarizer {
    public var id: String { ClipDiarizerID.sortformer }
    private let directory: URL
    private let runner = SortformerRunner()

    public init(directory: URL = DataLocations.sortformerModels) {
        self.directory = directory
    }

    /// The compiled model, `<directory>/<repo>/v3/fp16/…mlmodelc`.
    var modelFolder: URL {
        directory
            .appending(path: Repo.sortformer.folderName, directoryHint: .isDirectory)
            .appending(path: ModelNames.Sortformer.offlineBundle(precision: .fp16), directoryHint: .isDirectory)
    }

    public func isInstalled() -> Bool {
        FileManager.default.fileExists(atPath: modelFolder.appending(path: "coremldata.bin").path)
    }

    /// Bytes on disk, or nil when it isn't installed.
    public func sizeOnDisk() -> Int64? {
        guard isInstalled(),
              let files = FileManager.default.enumerator(
                  at: directory, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]
              )
        else { return nil }
        var total: Int64 = 0
        for case let file as URL in files {
            total += Int64((try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    public func spans(of samples: [Float]) async throws -> [SpeakerSpan] {
        guard isInstalled() else {
            await runner.reset()
            throw ClipDiarizerError.notInstalled
        }
        guard !samples.isEmpty else { return [] }
        return try await runner.spans(of: samples, modelFolder: modelFolder)
    }
}

extension SortformerClipDiarizer {
    /// Downloads the model, reporting progress from 0 to 1. Files already on
    /// disk aren't fetched again.
    public func install(progress: @escaping @Sendable (Double) -> Void) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try await ModelHub.download(
            .sortformer, to: directory, variant: ModelNames.Sortformer.offlineBundle(precision: .fp16)
        ) { progress($0.fractionCompleted) }
        progress(1)
    }

    /// Deletes the downloaded model.
    public func remove() throws {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.removeItem(at: directory)
    }
}

/// Holds the loaded Sortformer model, which isn't safe to share between
/// threads, and runs one recording at a time.
private actor SortformerRunner {
    private var diarizer: OfflineSortformerDiarizer?

    func reset() { diarizer = nil }

    func spans(of samples: [Float], modelFolder: URL) throws -> [SpeakerSpan] {
        let diarizer = try loaded(modelFolder)
        let timeline = try diarizer.processComplete(samples)
        return timeline.speakers.values
            .flatMap { speaker in
                speaker.finalizedSegments.map {
                    SpeakerSpan(speaker: String(speaker.index), start: Double($0.startTime), end: Double($0.endTime))
                }
            }
            .sorted { ($0.start, $0.speaker) < ($1.start, $1.speaker) }
    }

    /// Loads the compiled model straight from its folder: a failed load
    /// throws and leaves the files alone.
    private func loaded(_ modelFolder: URL) throws -> OfflineSortformerDiarizer {
        if let diarizer { return diarizer }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        let model = try MLModel(contentsOf: modelFolder, configuration: configuration)
        let fresh = OfflineSortformerDiarizer()
        fresh.initialize(models: try OfflineSortformerModels(config: fresh.config, main: model))
        diarizer = fresh
        return fresh
    }
}

/// A value made once and shared, made again after ``reset()``.
private actor LoadedOnce<Value: Sendable> {
    private var value: Value?

    func reset() { value = nil }

    func get(_ make: @Sendable () throws -> Value) rethrows -> Value {
        if let value { return value }
        let made = try make()
        value = made
        return made
    }
}
