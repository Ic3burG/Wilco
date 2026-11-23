import Foundation

/// Names of the strong models that transcribe kept clips after a show. They
/// go into a clip's labels, so they must not change.
public enum ClipVoterID {
    public static let parakeetUltra = "parakeet-ultra"
    public static let whisperLarge = "whisper-large-v3"
    public static let appleLongForm = "apple-longform"
}

/// Decides whether the voters agree on what a clip says.
public enum ClipAgreement {
    /// Voters that sit out a clip because the channel's live engine is one of
    /// them: a model agreeing with itself proves nothing about the live line.
    public static func sittingOut(engine: String, whisperModel: String?) -> Set<String> {
        switch engine {
        case SpeechEngine.whisper.rawValue where whisperModel == WhisperModel.large.rawValue:
            [ClipVoterID.whisperLarge]
        case SpeechEngine.longForm.rawValue:
            [ClipVoterID.appleLongForm]
        default:
            []
        }
    }

    /// `voters` in preference order. Two voting: both must match. Three or
    /// more: any two. Fewer than two after sitting out (or without a
    /// candidate): `.notEnoughVoters`. The text is the first matching voter's
    /// own text (casing kept); match = equal `TranscriptNormalizer.words`.
    /// Empty texts never match.
    public static func words(
        candidates: [String: String], voters: [String], sittingOut: Set<String>
    ) -> (verdict: WordsVerdict, text: String?) {
        let voting = voters.filter { !sittingOut.contains($0) && candidates[$0] != nil }
        guard voting.count >= 2 else { return (.notEnoughVoters, nil) }
        let words = voting.map { TranscriptNormalizer.words(candidates[$0] ?? "") }
        for first in words.indices where !words[first].isEmpty {
            for second in words.indices where second > first && words[second] == words[first] {
                return (.agreed, candidates[voting[first]])
            }
        }
        return (.disputed, nil)
    }
}
