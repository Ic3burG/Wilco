import Foundation

/// The show a session was recorded with, kept beside its transcript as
/// `Session yyyy-MM-dd HHmm-ss.wilco` (a plain ``ShowDocument``), so a report
/// opened later is labelled with that show and not whichever is open now.
public enum SessionShow {
    public static func url(forTranscript transcript: URL) -> URL {
        transcript.deletingPathExtension().appendingPathExtension(ShowFile.fileExtension)
    }

    public static func save(_ show: ShowDocument, forTranscript transcript: URL) throws {
        try WilcoJSON.encoder().encode(show).write(to: url(forTranscript: transcript), options: .atomic)
    }

    /// Nil when the session has no copy (recorded before copies were kept) or
    /// the copy can't be read.
    public static func load(forTranscript transcript: URL) -> ShowDocument? {
        guard let data = try? Data(contentsOf: url(forTranscript: transcript)) else { return nil }
        return try? WilcoJSON.decoder().decode(ShowDocument.self, from: data)
    }

    /// For a session without a copy: the candidate sharing the most channels
    /// with the lines, the earlier candidate on a tie, nil if none share any.
    /// Copied shows keep their channel IDs, so this is a best guess.
    public static func bestMatch(for segments: [TranscriptSegment], among candidates: [ShowDocument]) -> ShowDocument? {
        let spoke = Set(segments.map(\.channelID))
        var best: (show: ShowDocument, shared: Int)?
        for show in candidates {
            let shared = show.channels.count { spoke.contains($0.id) }
            if shared > (best?.shared ?? 0) { best = (show, shared) }
        }
        return best?.show
    }
}
