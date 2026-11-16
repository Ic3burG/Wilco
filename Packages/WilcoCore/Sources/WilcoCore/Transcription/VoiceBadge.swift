import Foundation

/// Decisions for the letter column in the transcript.
public enum VoiceBadge {
    /// What the letter column shows for one line: `nil` when the channel has
    /// no column (feature off, or the voice model isn't installed), an empty
    /// string for a line that was never analysed (it keeps the column
    /// aligned), "·" for an analysed line whose voice is unknown, else the letter.
    public static func label(
        voice: String?, exchange: Int?, detectsVoiceChanges: Bool, modelInstalled: Bool
    ) -> String? {
        guard detectsVoiceChanges, modelInstalled else { return nil }
        if let voice { return voice }
        return exchange == nil ? "" : "·"
    }

    /// IDs of lines that begin a new turn: the voice or exchange differs from
    /// the previous line on the same channel. `segments` are oldest first.
    /// Lines with no voice information never start a turn.
    public static func turnStarts(in segments: [TranscriptSegment]) -> Set<UUID> {
        var previous: [UUID: TranscriptSegment] = [:]
        var starts = Set<UUID>()
        for segment in segments {
            if let before = previous[segment.channelID],
               segment.exchange != nil || segment.voice != nil,
               before.voice != segment.voice || before.exchange != segment.exchange {
                starts.insert(segment.id)
            }
            previous[segment.channelID] = segment
        }
        return starts
    }
}
