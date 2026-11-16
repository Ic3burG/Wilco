import Foundation
import WilcoCore

/// Which of Parakeet's models are on disk.
public struct ParakeetAvailability: Equatable, Sendable {
    /// The speech model; without it a Parakeet channel can't start.
    public var model: Bool
    /// The vocabulary (CTC) model; without it terms aren't boosted.
    public var vocabulary: Bool

    public init(model: Bool, vocabulary: Bool) {
        self.model = model
        self.vocabulary = vocabulary
    }

    public init(store: ParakeetModelStore) {
        self.init(model: store.isInstalled(), vocabulary: store.isVocabularyInstalled())
    }
}

/// What to do with running channels when a model is installed mid-session.
///
/// A Parakeet channel started without its speech model fails and doesn't try
/// again, and one started without the vocabulary model runs unboosted for the
/// rest of the run. Restarting just those picks the new model up; every other
/// channel keeps running, since a restart cuts the line in progress.
public enum ModelArrival {
    /// Whether to restart a running channel, given what was on disk when it
    /// started and what is now.
    public static func restarts(
        _ configuration: TranscriberConfiguration, status: TranscriberStatus?,
        startedWith: ParakeetAvailability, now: ParakeetAvailability
    ) -> Bool {
        guard configuration.engine == .parakeet, now.model else { return false }
        // A failed channel isn't transcribing, so starting it again loses nothing.
        if case .failed = status { return true }
        let boosts = ParakeetVocabulary.applies(
            language: ParakeetLanguages.language(for: configuration.localeIdentifier),
            terms: configuration.vocabulary
        )
        return boosts && !startedWith.vocabulary && now.vocabulary
    }
}
