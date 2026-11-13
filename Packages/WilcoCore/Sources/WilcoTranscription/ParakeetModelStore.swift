import FluidAudio
import Foundation
import WilcoCore

public enum ParakeetError: Error, Equatable, LocalizedError {
    case notInstalled
    /// The model that boosts a channel's vocabulary isn't downloaded.
    case vocabularyNotInstalled

    public var errorDescription: String? {
        switch self {
        case .notInstalled:
            "The Parakeet model isn't installed. Install it in Settings → Languages."
        case .vocabularyNotInstalled:
            "The Parakeet vocabulary model isn't installed. Install Parakeet again in Settings → Languages."
        }
    }
}

/// The Parakeet speech model on disk, loaded once for every channel that
/// uses it, and the smaller model that boosts a channel's vocabulary.
public actor ParakeetModelStore {
    private let directory: URL
    private var loaded: AsrManager?
    /// A load in progress, so channels starting together load the model once.
    private var loading: Task<AsrManager, Error>?
    private var loadedCTC: CtcModels?
    private var loadingCTC: Task<CtcModels, Error>?

    public init(directory: URL = DataLocations.parakeetModels) {
        self.directory = directory
    }

    /// FluidAudio keeps a model repository in a folder named for it.
    private nonisolated var tdtFolder: URL {
        directory.appending(path: AsrModels.defaultCacheDirectory(for: .v3).lastPathComponent, directoryHint: .isDirectory)
    }

    /// The vocabulary model (Parakeet CTC 110M) lives under `ctc-110m`, in
    /// the repository folder FluidAudio's downloader names.
    private nonisolated var ctcFolder: URL {
        directory.appending(path: "ctc-110m", directoryHint: .isDirectory)
            .appending(path: CtcModels.defaultCacheDirectory(for: .ctc110m).lastPathComponent, directoryHint: .isDirectory)
    }

    /// Whether the speech model is installed. The vocabulary model is
    /// optional: without it channels transcribe without boosting.
    public nonisolated func isInstalled() -> Bool {
        AsrModels.modelsExist(at: tdtFolder, version: .v3)
    }

    public nonisolated func isVocabularyInstalled() -> Bool {
        CtcModels.modelsExist(at: ctcFolder)
    }

    /// Bytes the models take on disk, or nil when the speech model isn't installed.
    public nonisolated func sizeOnDisk() -> Int64? {
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

    /// Downloads the speech model and the vocabulary model, reporting
    /// progress from 0 to 1. Models already on disk aren't fetched again.
    public nonisolated func install(progress: @escaping @Sendable (Double) -> Void) async throws {
        // Roughly the share of the download each model takes.
        let speechShare = 0.85
        _ = try await AsrModels.download(to: tdtFolder, version: .v3) { progress($0.fractionCompleted * speechShare) }
        try await CtcModels.download(to: ctcFolder, variant: .ctc110m) {
            progress(speechShare + $0.fractionCompleted * (1 - speechShare))
        }
        progress(1)
    }

    /// Deletes the downloaded models. Don't remove them while channels use them.
    public nonisolated func remove() throws {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.removeItem(at: directory)
    }

    /// The loaded recognizer, shared by every channel.
    func manager() async throws -> AsrManager {
        // Checked before the cache so a removed model stops being served.
        guard isInstalled() else {
            loaded = nil
            throw ParakeetError.notInstalled
        }
        if let loaded { return loaded }
        let folder = tdtFolder
        let task: Task<AsrManager, Error>
        if let loading {
            task = loading
        } else {
            task = Task {
                let models = try await AsrModels.load(from: folder, version: .v3)
                let manager = AsrManager(config: .default)
                try await manager.loadModels(models)
                return manager
            }
            loading = task
        }
        do {
            let manager = try await task.value
            loaded = manager
            if loading == task { loading = nil }
            return manager
        } catch {
            // A later load may have replaced this one; leave it alone.
            if loading == task { loading = nil }
            throw error
        }
    }

    /// The loaded vocabulary model, shared by every channel. Throws
    /// `vocabularyNotInstalled` rather than downloading it.
    func ctcModels() async throws -> CtcModels {
        guard isVocabularyInstalled() else {
            loadedCTC = nil
            throw ParakeetError.vocabularyNotInstalled
        }
        if let loadedCTC { return loadedCTC }
        let folder = ctcFolder
        let task: Task<CtcModels, Error>
        if let loadingCTC {
            task = loadingCTC
        } else {
            task = Task { try await CtcModels.load(from: folder, variant: .ctc110m) }
            loadingCTC = task
        }
        do {
            let models = try await task.value
            loadedCTC = models
            if loadingCTC == task { loadingCTC = nil }
            return models
        } catch {
            if loadingCTC == task { loadingCTC = nil }
            throw error
        }
    }

    /// Tests only: treat `manager` as already loaded.
    func adopt(_ manager: AsrManager) {
        loaded = manager
    }
}
