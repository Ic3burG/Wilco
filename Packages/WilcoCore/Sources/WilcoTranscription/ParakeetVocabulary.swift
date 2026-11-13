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

    /// Whether to use a rescored line in place of the original. It must
    /// differ, and carry exactly the same numbers, digits and spoken words
    /// alike. The rescorer can replace a span holding a cue number ("club
    /// Q12" became "QLab"), and a term such as "LX 42" from a rule phrase can
    /// bring a number nobody said. A line's numbers must come from the speech
    /// engine, never from the booster: a wrong cue number is worse than a
    /// missed term.
    static func accepts(original: String, rescored: String) -> Bool {
        original != rescored && numbers(in: original) == numbers(in: rescored)
    }

    /// Spoken number words, including the ones callers use for digits.
    private static let numberWords: Set<String> = [
        "zero", "oh", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
        "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen",
        "nineteen", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety",
        "hundred", "thousand", "double",
    ]

    /// How many times each digit run and number word appears.
    private static func numbers(in text: String) -> [String: Int] {
        var counts: [String: Int] = [:]
        for digits in text.split(whereSeparator: { !$0.isNumber }) {
            counts[String(digits), default: 0] += 1
        }
        for word in text.lowercased().split(whereSeparator: { !$0.isLetter }) where numberWords.contains(String(word)) {
            counts[String(word), default: 0] += 1
        }
        return counts
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
