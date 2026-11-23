import Foundation

/// A past session in a few numbers, for trends and for name counts.
public struct SessionSummary: Sendable, Identifiable {
    /// The session's `.jsonl` file.
    public var id: URL
    public var started: Date
    public var showName: String
    public var lines: Int
    public var fillerShare: Double
    public var unclearShare: Double
    public var delayP90: Double?
    public var names = NameCounts()

    public init(id: URL, started: Date, showName: String, lines: Int, fillerShare: Double, unclearShare: Double,
                delayP90: Double?) {
        self.id = id
        self.started = started
        self.showName = showName
        self.lines = lines
        self.fillerShare = fillerShare
        self.unclearShare = unclearShare
        self.delayP90 = delayP90
    }
}

public enum SessionHistory {
    public static let unknownShow = "Unknown show"

    /// Summarises one session. Its show is the copy saved beside it, else
    /// the candidate sharing the most channels.
    public static func summary(transcript: URL, candidates: [ShowDocument]) throws -> SessionSummary {
        let segments = TranscriptFile.segments(in: try Data(contentsOf: transcript))
        let stats = SessionStats.make(segments)
        let show = SessionShow.load(forTranscript: transcript) ?? SessionShow.bestMatch(for: segments, among: candidates)
        let name = show?.name.trimmingCharacters(in: .whitespaces) ?? ""
        var summary = SessionSummary(
            id: transcript,
            started: started(fromFileName: transcript) ?? Date(timeIntervalSince1970: stats.start),
            showName: name.isEmpty ? unknownShow : name,
            lines: stats.lines, fillerShare: stats.fillerShare, unclearShare: stats.unclearShare,
            delayP90: stats.delayP90
        )
        summary.names = NameCounts.make(segments)
        return summary
    }

    /// Every readable, non-empty session in a folder, newest first.
    public static func summaries(in folder: URL, candidates: [ShowDocument]) throws -> [SessionSummary] {
        try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "jsonl" }
            .compactMap { try? summary(transcript: $0, candidates: candidates) }
            .filter { $0.lines > 0 }
            .sorted { $0.started > $1.started }
    }

    /// Sessions of the named show other than `excluding`, newest first.
    public static func sameShow(as name: String, in all: [SessionSummary], excluding: URL) -> [SessionSummary] {
        all.filter { $0.showName == name && $0.id.resolvingSymlinksInPath() != excluding.resolvingSymlinksInPath() }
            .sorted { $0.started > $1.started }
    }

    /// "Session 2026-11-07 2225-51.jsonl" → its local start time.
    public static func started(fromFileName url: URL) -> Date? {
        let name = url.deletingPathExtension().lastPathComponent
        guard name.hasPrefix("Session ") else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HHmm-ss"
        return formatter.date(from: String(name.dropFirst("Session ".count)))
    }
}
