import Foundation

/// A session's saved clips and the answers worked out for them.
public struct SessionClips: Sendable {
    public var manifest: ClipManifest
    public var labels: ClipLabels

    public init(manifest: ClipManifest, labels: ClipLabels) {
        self.manifest = manifest
        self.labels = labels
    }

    /// Nil when the session has no `.clips` folder, or it has no manifest or no labels yet.
    public static func load(forTranscript transcript: URL) -> SessionClips? {
        let folder = ClipsFolder.url(forTranscript: transcript)
        guard let manifest = ClipsFolder.loadManifest(in: folder),
              let labels = ClipsFolder.loadLabels(in: folder) else { return nil }
        return SessionClips(manifest: manifest, labels: labels)
    }
}

/// How often the live transcript got the words of the hard lines wrong.
public enum ClipAccuracy {
    /// A line can start a little before the clip does (the clip is cut from
    /// the audio that line's speech began in).
    static let leadSeconds = 0.5

    /// Final lines on the clip's channel with sessionOffset in [start − 0.5, start + duration], in order, joined by spaces.
    public static func liveText(for clip: ClipRecord, in segments: [TranscriptSegment]) -> String {
        let from = clip.sessionOffset - leadSeconds
        let to = clip.sessionOffset + clip.duration
        return segments
            .filter { $0.isFinal && $0.channelID == clip.channel && $0.sessionOffset >= from && $0.sessionOffset <= to }
            .sorted { $0.sessionOffset < $1.sessionOffset }
            .map(\.text)
            .joined(separator: " ")
    }

    /// Per channel: clips with an answer, and the live text's word errors against the answers.
    /// Clips without a label or without an answer are left out.
    public static func perChannel(segments: [TranscriptSegment], clips: SessionClips) -> [UUID: (clips: Int, errors: WordErrors)] {
        let answers = Dictionary(clips.labels.clips.compactMap { label in label.answer.map { (label.clip, $0) } },
                                 uniquingKeysWith: { first, _ in first })
        var result: [UUID: (clips: Int, errors: WordErrors)] = [:]
        for clip in clips.manifest.clips {
            guard let answer = answers[clip.id] else { continue }
            let errors = WordErrorRate.compare(
                reference: TranscriptNormalizer.words(answer),
                hypothesis: TranscriptNormalizer.words(liveText(for: clip, in: segments)))
            let soFar = result[clip.channel] ?? (0, WordErrors())
            result[clip.channel] = (soFar.clips + 1, soFar.errors + errors)
        }
        return result
    }
}
