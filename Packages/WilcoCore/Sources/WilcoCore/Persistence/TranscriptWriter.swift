import Foundation

/// Appends settled lines to a session's `.jsonl` file as they happen, so
/// clearing the on-screen log never discards the record. A copy of the show
/// is kept beside it (see ``SessionShow``).
public final class TranscriptWriter {
    public let url: URL
    private let show: ShowDocument?
    /// Stamped on every line that doesn't carry its own. Fixed for the
    /// session, so a Mac that changes zone mid-show keeps one clock.
    public let timeZone: TimeZone
    private var handle: FileHandle?

    public init(url: URL, show: ShowDocument? = nil, timeZone: TimeZone = .current) {
        self.url = url
        self.show = show
        self.timeZone = timeZone
    }

    deinit {
        try? handle?.close()
    }

    public func append(_ segment: TranscriptSegment) throws {
        var segment = segment
        if segment.timeZone == nil { segment.timeZone = timeZone.identifier }
        try fileHandle().write(contentsOf: TranscriptFile.line(for: segment))
    }

    /// Updates the show copy to the show as it is at the end of capture, so
    /// names and channels changed mid-session are kept. Does nothing for a
    /// session in which nobody spoke.
    public func finish(show: ShowDocument) {
        guard handle != nil else { return }
        try? SessionShow.save(show, forTranscript: url)
    }

    /// The file is created on the first line, so a session in which nobody
    /// spoke leaves no empty file behind. The show copy is written then too.
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
        if let show { try? SessionShow.save(show, forTranscript: url) }
        return handle
    }
}
