import FluidAudio
import Foundation
import Testing
import WilcoCore
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

    @Test func englishOnlyNoticeCountsEveryTermTheChannelGets() {
        // Rule phrases are part of a channel's vocabulary, so a French
        // channel with only a rule phrase still needs telling.
        var show = ShowDocument()
        let channel = show.addChannel(engine: .parakeet)
        show.rules = [AutomationRule(name: "Standby", phrases: ["standby"])]
        let terms = show.vocabulary(for: channel.id)
        #expect(!terms.isEmpty)
        #expect(ParakeetVocabulary.noticeNeeded(language: .french, terms: terms))
        #expect(ParakeetVocabulary.noticeNeeded(language: nil, terms: terms))
        #expect(!ParakeetVocabulary.noticeNeeded(language: .english, terms: terms))
        #expect(!ParakeetVocabulary.noticeNeeded(language: .french, terms: [" "]))
    }

    @Test func conservativeThresholds() {
        #expect(ParakeetVocabulary.thresholds == VocabularyBoostingSession.Thresholds(cbw: 0, minSimilarity: 0.7))
    }

    @Test func rescoreThatChangesANumberIsRefused() {
        // Seen with "QLab" boosted: the rescorer swapped the cue number out.
        #expect(!ParakeetVocabulary.accepts(original: "Standby Club Q12.", rescored: "Standby Club QLab."))
        #expect(!ParakeetVocabulary.accepts(original: "club Q12", rescored: "QLab"))
        #expect(!ParakeetVocabulary.accepts(original: "And I clam to 12.", rescored: "And I clam to QLab."))
        #expect(!ParakeetVocabulary.accepts(original: "Go 4 and 4.", rescored: "Go 4 and Tait."))
        // A term mustn't bring a number nobody said, or turn a spoken one into digits.
        #expect(!ParakeetVocabulary.accepts(original: "Ellex forty three", rescored: "LX 42"))
        #expect(!ParakeetVocabulary.accepts(original: "Ellex forty two", rescored: "LX 42"))
        #expect(!ParakeetVocabulary.accepts(original: "Standby Ellex", rescored: "Standby LX 42"))
        #expect(!ParakeetVocabulary.accepts(original: "cue twelve", rescored: "QLab"))
        #expect(!ParakeetVocabulary.accepts(original: "Fly forty-two in", rescored: "Fly Nivoflex in"))
    }

    @Test func rescoreThatOnlyFixesATermIsAccepted() {
        #expect(ParakeetVocabulary.accepts(original: "standby the kineses rig", rescored: "standby the Kinesys rig"))
        #expect(ParakeetVocabulary.accepts(original: "Cue 42, kineses go.", rescored: "Cue 42 Kinesys go"))
        #expect(ParakeetVocabulary.accepts(original: "Standby forty two on the kineses",
                                           rescored: "Standby forty two on the Kinesys"))
        // Nothing changed: nothing to accept.
        #expect(!ParakeetVocabulary.accepts(original: "Deck is clear.", rescored: "Deck is clear."))
    }

    private func token(_ text: String, _ start: Double, _ end: Double) -> TokenTiming {
        TokenTiming(token: text, tokenId: 0, startTime: start, endTime: end, confidence: 1)
    }

    @Test func tokensJoinIntoWordsAtWordStarts() {
        // Pieces starting with "▁" (or a space, as FluidAudio hands them on)
        // start a word; the rest continue it.
        let words = ParakeetRecognizer.words(from: [
            token("▁Stand", 0.0, 0.3), token("by", 0.3, 0.5), token(" L", 0.5, 0.6), token("X", 0.6, 0.8),
            token(" 42", 0.8, 1.2), token(".", 1.2, 1.24),
        ])
        #expect(words == [
            TimedWord(text: "Standby", start: 0.0, end: 0.5),
            TimedWord(text: "LX", start: 0.5, end: 0.8),
            TimedWord(text: "42.", start: 0.8, end: 1.24),
        ])
    }

    @Test func rescoredTextKeepsTimingsOnlyWhenTheWordsLineUp() {
        let words = [
            TimedWord(text: "kineses", start: 0, end: 0.5), TimedWord(text: "rig", start: 0.5, end: 0.8),
            TimedWord(text: "go", start: 0.8, end: 1.0),
        ]
        // One word replaced by one: same times, the new spelling.
        #expect(ParakeetVocabulary.retimed(words, to: "Kinesys rig go").map(\.text) == ["Kinesys", "rig", "go"])
        #expect(ParakeetVocabulary.retimed(words, to: "Kinesys rig go").map(\.start) == [0, 0.5, 0.8])
        // Two words became one: the times no longer match, so none.
        #expect(ParakeetVocabulary.retimed(words, to: "Kinesys go").isEmpty)
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
