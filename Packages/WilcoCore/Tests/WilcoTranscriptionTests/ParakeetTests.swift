import FluidAudio
import Foundation
import Testing
@testable import WilcoTranscription

@Suite struct ParakeetTests {
    @Test func languageHintFromChannelIdentifier() {
        #expect(ParakeetLanguages.language(for: "") == nil)
        #expect(ParakeetLanguages.language(for: "en_US") == .english)
        #expect(ParakeetLanguages.language(for: "fr-CA") == .french)
        #expect(ParakeetLanguages.language(for: "ja_JP") == nil)
    }

    @Test func missingModelFailsTheChannelNotTheApp() async {
        let store = ParakeetModelStore(directory: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
        #expect(!store.isInstalled())
        await #expect(throws: ParakeetError.notInstalled) { _ = try await store.manager() }
    }

    @Test func removedModelIsNotServedFromTheCache() async {
        // A manager loaded before the model was removed mustn't outlive it.
        let store = ParakeetModelStore(directory: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
        await store.adopt(AsrManager(config: .default))
        await #expect(throws: ParakeetError.notInstalled) { _ = try await store.manager() }
    }

    @Test func missingVocabularyModelIsReported() async {
        let store = ParakeetModelStore(directory: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
        #expect(!store.isVocabularyInstalled())
        await #expect(throws: ParakeetError.vocabularyNotInstalled) { _ = try await store.ctcModels() }
    }

    @Test func vocabularyOnlyForEnglish() {
        #expect(ParakeetVocabulary.applies(language: .english, terms: ["Kinesys"]))
        #expect(!ParakeetVocabulary.applies(language: nil, terms: ["Kinesys"]))
        #expect(!ParakeetVocabulary.applies(language: .french, terms: ["Kinesys"]))
        #expect(!ParakeetVocabulary.applies(language: .english, terms: ["  "]))
        #expect(!ParakeetVocabulary.applies(language: .english, terms: []))
    }

    @Test func conservativeThresholds() {
        #expect(ParakeetVocabulary.thresholds == VocabularyBoostingSession.Thresholds(cbw: 0, minSimilarity: 0.7))
    }

    @Test func rescoreThatLosesACueNumberIsRefused() {
        // Seen with "QLab" boosted: the rescorer swapped the cue number out.
        #expect(!ParakeetVocabulary.keepsNumbers(original: "Standby Club Q12.", rescored: "Standby Club QLab."))
        #expect(!ParakeetVocabulary.keepsNumbers(original: "And I clam to 12.", rescored: "And I clam to QLab."))
        #expect(!ParakeetVocabulary.keepsNumbers(original: "Go 4 and 4.", rescored: "Go 4 and Tait."))
        #expect(ParakeetVocabulary.keepsNumbers(original: "Stand by the kineses rig.", rescored: "Stand by the Kinesys."))
        #expect(ParakeetVocabulary.keepsNumbers(original: "Cue 42, go.", rescored: "Cue 42 go"))
        #expect(ParakeetVocabulary.keepsNumbers(original: "Ellex forty two", rescored: "LX 42"))
    }

    @Test func blankTermsAreDropped() {
        #expect(ParakeetVocabulary.cleaned([" Kinesys ", "", "  ", "LX 42"]) == ["Kinesys", "LX 42"])
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["WILCO_ASR_TESTS"] != nil))
    func transcribesASpokenCall() async throws {
        let samples = try sayClip("Standby lighting cue forty two")
        let recognition = try await ParakeetRecognizer(store: Self.testStore(), language: .english).recognize(samples)
        #expect(recognition?.text.lowercased().contains("lighting") == true)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["WILCO_ASR_TESTS"] != nil))
    func awkwardTermsBuildAndRun() async throws {
        let store = Self.testStore()
        // Fetches the vocabulary model (about 100 MB) the first time.
        try await store.install { _ in }
        let recognizer = ParakeetRecognizer(store: store, language: .english,
                                            vocabulary: ["Q5", "LX 42", "D.S.M.", "Kinesys"])
        // Daniel: Parakeet hears "kineses", which the conservative
        // thresholds correct. Samantha's "Kennes'" scores better on the audio
        // than "Kinesys" at cbw 0, so it is (correctly) left alone.
        let samples = try sayClip("Standby the Kinesys rig", voice: "Daniel (English (UK))")
        let plain = try await ParakeetRecognizer(store: store, language: .english).recognize(samples)
        #expect(plain?.text.contains("Kinesys") == false)
        #expect(try await recognizer.recognize(samples)?.text.contains("Kinesys") == true)
        // Every term survives tokenization, including ones the spotter skips.
        #expect(await recognizer.booster?.current()?.vocabulary.terms.count == 4)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["WILCO_ASR_TESTS"] != nil))
    func boostingKeepsTheCueNumber() async throws {
        let store = Self.testStore()
        try await store.install { _ in }
        // Moira: Parakeet hears "Stand by club Q12", which the rescorer
        // would turn into "Stand by QLab".
        let samples = try sayClip("Standby Qlab cue twelve", voice: "Moira (English (Ireland))")
        let recognition = try await ParakeetRecognizer(store: store, language: .english, vocabulary: ["QLab"])
            .recognize(samples)
        #expect(recognition?.text.contains("12") == true)
    }

    /// The app's model when installed; otherwise FluidAudio's default cache,
    /// which holds the same files, to avoid a fresh download.
    private static func testStore() -> ParakeetModelStore {
        let store = ParakeetModelStore()
        return store.isInstalled()
            ? store : ParakeetModelStore(directory: AsrModels.defaultCacheDirectory(for: .v3).deletingLastPathComponent())
    }
}
