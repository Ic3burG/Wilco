import FluidAudio
import Foundation

/// Boosting a channel's vocabulary on Parakeet. A separate CTC model listens
/// for the terms in each utterance and replaces words in the transcript that
/// sound like one. The CTC model's tokenizer is English, so only English
/// channels get it.
public enum ParakeetVocabulary {
    /// Whether a channel with this language and these terms is boosted.
    public static func applies(language: Language?, terms: [String]) -> Bool {
        language == .english && !cleaned(terms).isEmpty
    }

    /// Conservative: a term must win on the audio alone and look like the
    /// heard words, so correctly heard words are rarely replaced.
    public static let thresholds = VocabularyBoostingSession.Thresholds(cbw: 0, minSimilarity: 0.7)

    /// Whether a rescored line still has every number the original had. The
    /// rescorer can replace a span that holds a cue number ("Club Q12" became
    /// "QLab"), and a wrong cue number is worse than a missed term, so such
    /// a rescore is thrown away.
    static func keepsNumbers(original: String, rescored: String) -> Bool {
        var remaining = numbers(in: rescored)
        for number in numbers(in: original) {
            guard let index = remaining.firstIndex(of: number) else { return false }
            remaining.remove(at: index)
        }
        return true
    }

    /// Runs of digits, in order.
    private static func numbers(in text: String) -> [Substring] {
        text.split(whereSeparator: { !$0.isNumber })
    }

    /// The terms, trimmed, without blanks.
    static func cleaned(_ terms: [String]) -> [String] {
        terms.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    /// A session for these terms. The session tokenizes plain text with the
    /// CTC model's tokenizer; terms that give no tokens are dropped.
    static func session(terms: [String], ctcModels: CtcModels) async throws -> VocabularyBoostingSession {
        let context = CustomVocabularyContext(terms: cleaned(terms).map { CustomVocabularyTerm(text: $0) })
        return try await VocabularyBoostingSession(vocabulary: context, ctcModels: ctcModels, thresholds: thresholds)
    }
}

/// One recognizer's boosting session, built on first use once the CTC model
/// has loaded.
actor ParakeetBooster {
    private let store: ParakeetModelStore
    private let terms: [String]
    private var session: VocabularyBoostingSession?
    private var building: Task<VocabularyBoostingSession, Error>?
    /// Set once building has failed, so later utterances don't retry it.
    private var unavailable = false

    init(store: ParakeetModelStore, terms: [String]) {
        self.store = store
        self.terms = terms
    }

    /// The session, or nil when boosting isn't available. A missing or
    /// broken CTC model never fails transcription: the channel carries on
    /// without boosting. Nothing is logged here because this runs for every
    /// utterance; the Languages settings show whether the model is installed.
    func current() async -> VocabularyBoostingSession? {
        if let session { return session }
        if unavailable { return nil }
        let task: Task<VocabularyBoostingSession, Error>
        if let building {
            task = building
        } else {
            let store = store
            let terms = terms
            task = Task {
                try await ParakeetVocabulary.session(terms: terms, ctcModels: store.ctcModels())
            }
            building = task
        }
        do {
            let built = try await task.value
            session = built
            building = nil
            return built
        } catch {
            unavailable = true
            building = nil
            return nil
        }
    }
}
