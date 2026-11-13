import FluidAudio
import Foundation
import WilcoCore

public enum ParakeetError: Error, Equatable, LocalizedError {
    case notInstalled

    public var errorDescription: String? {
        "The Parakeet model isn't installed. Install it in Settings → Languages."
    }
}

/// The Parakeet speech model on disk, loaded once for every channel that
/// uses it.
public actor ParakeetModelStore {
    private let directory: URL
    private var loaded: AsrManager?
    /// A load in progress, so channels starting together load the model once.
    private var loading: Task<AsrManager, Error>?

    public init(directory: URL = DataLocations.parakeetModels) {
        self.directory = directory
    }

    /// FluidAudio keeps a model repository in a folder named for it.
    private nonisolated var tdtFolder: URL {
        directory.appending(path: AsrModels.defaultCacheDirectory(for: .v3).lastPathComponent, directoryHint: .isDirectory)
    }

    public nonisolated func isInstalled() -> Bool {
        AsrModels.modelsExist(at: tdtFolder, version: .v3)
    }

    /// Bytes the model takes on disk, or nil when it isn't installed.
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

    /// Downloads the model, reporting progress from 0 to 1.
    public nonisolated func install(progress: @escaping @Sendable (Double) -> Void) async throws {
        _ = try await AsrModels.download(to: tdtFolder, version: .v3) { progress($0.fractionCompleted) }
    }

    /// Deletes the downloaded model. Don't remove it while channels use it.
    public nonisolated func remove() throws {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.removeItem(at: directory)
    }

    /// The loaded recognizer, shared by every channel.
    func manager() async throws -> AsrManager {
        if let loaded { return loaded }
        guard isInstalled() else { throw ParakeetError.notInstalled }
        let folder = tdtFolder
        let task = loading ?? Task {
            let models = try await AsrModels.load(from: folder, version: .v3)
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            return manager
        }
        loading = task
        do {
            let manager = try await task.value
            loaded = manager
            loading = nil
            return manager
        } catch {
            loading = nil
            throw error
        }
    }
}
