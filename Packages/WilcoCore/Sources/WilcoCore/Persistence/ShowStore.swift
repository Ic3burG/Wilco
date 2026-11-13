import Foundation

/// Reads and writes the open show (`Current.wilco`).
public struct ShowStore: Sendable {
    public struct LoadResult: Sendable {
        public var document: ShowDocument
        /// Set when the existing file could not be read and was moved here.
        public var recoveredFileURL: URL?
    }

    public let directory: URL

    public init(directory: URL = DataLocations.root) {
        self.directory = directory
    }

    public var fileURL: URL { directory.appending(path: ShowFile.currentName) }

    public func load() -> LoadResult {
        let fileManager = FileManager.default
        guard let data = try? Data(contentsOf: fileURL) else {
            return LoadResult(document: ShowDocument())
        }
        do {
            return LoadResult(document: try WilcoJSON.decoder().decode(ShowDocument.self, from: data))
        } catch {
            let stamp = Int(Date().timeIntervalSince1970)
            let kept = directory.appending(path: "Current-unreadable-\(stamp).\(ShowFile.fileExtension)")
            try? fileManager.moveItem(at: fileURL, to: kept)
            return LoadResult(document: ShowDocument(), recoveredFileURL: kept)
        }
    }

    public func save(_ document: ShowDocument) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try WilcoJSON.encoder().encode(document).write(to: fileURL, options: .atomic)
    }
}
