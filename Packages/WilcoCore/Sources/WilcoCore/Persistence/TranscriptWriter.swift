import Foundation

/// Appends settled lines to a session's `.jsonl` file as they happen, so
/// clearing the on-screen log never discards the record.
public final class TranscriptWriter {
    public let url: URL
    private var handle: FileHandle?

    public init(url: URL) {
        self.url = url
    }

    deinit {
        try? handle?.close()
    }

    public func append(_ segment: TranscriptSegment) throws {
        try fileHandle().write(contentsOf: TranscriptFile.line(for: segment))
    }

    /// The file is created on the first line, so a session in which nobody
    /// spoke leaves no empty file behind.
    private func fileHandle() throws -> FileHandle {
        if let handle { return handle }
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fileManager.fileExists(atPath: url.path) {
            fileManager.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        self.handle = handle
        return handle
    }
}
