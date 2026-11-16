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

    // MARK: - Models installed mid-session

    private func parakeet(_ terms: [String] = [], locale: String = "en_US") -> TranscriberConfiguration {
        var show = ShowDocument()
        var channel = show.addChannel(engine: .parakeet)
        channel.localeIdentifier = locale
        show.globalVocabulary = terms
        return TranscriberConfiguration(channel: channel, show: show)
    }

    private let none = ParakeetAvailability(model: false, vocabulary: false)
    private let modelOnly = ParakeetAvailability(model: true, vocabulary: false)
    private let both = ParakeetAvailability(model: true, vocabulary: true)

    @Test func failedParakeetChannelRestartsOnceItsModelIsInstalled() {
        let failed = TranscriberStatus.failed("Could not load the speech model")
        #expect(ModelArrival.restarts(parakeet(), status: failed, startedWith: none, now: modelOnly))
        #expect(!ModelArrival.restarts(parakeet(), status: failed, startedWith: none, now: none),
                "still nothing to load")
    }

    @Test func channelRunningWithoutItsVocabularyModelRestartsWhenItArrives() {
        let boosted = parakeet(["Kinesys"])
        #expect(ModelArrival.restarts(boosted, status: .listening, startedWith: modelOnly, now: both))
        #expect(!ModelArrival.restarts(boosted, status: .listening, startedWith: both, now: both), "already boosting")
        #expect(!ModelArrival.restarts(boosted, status: .listening, startedWith: modelOnly, now: modelOnly))
    }

    @Test func healthyChannelsKeepRunning() {
        // Nothing to boost: no terms, or a language the booster can't do.
        #expect(!ModelArrival.restarts(parakeet(), status: .listening, startedWith: modelOnly, now: both))
        #expect(!ModelArrival.restarts(
            parakeet(["Kinesys"], locale: "fr_FR"), status: .listening, startedWith: modelOnly, now: both
        ))
        // Other engines never wait on Parakeet's models.
        var show = ShowDocument()
        let whisper = TranscriberConfiguration(channel: show.addChannel(engine: .whisper), show: show)
        #expect(!ModelArrival.restarts(whisper, status: .failed("x"), startedWith: none, now: both))
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
        // Daniel: Parakeet hears "kineses". Only the rescorer's acoustic
        // rescue turned that into "Kinesys", and it took "rig" with it ("Stand
        // by the Kinesys."). With the rescue off the line is left as heard:
        // a missed term costs less than a wrong word, and far less than a
        // rule phrase nobody said.
        let samples = try sayClip("Standby the Kinesys rig", voice: sayVoice("Daniel"))
        let plain = try await ParakeetRecognizer(store: store, language: .english).recognize(samples)
        #expect(plain?.text.contains("Kinesys") == false)
        let boosted = try await recognizer.recognize(samples)
        #expect(boosted?.text.lowercased().contains("rig") == true)
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

    /// Short, everyday terms must not replace words that sound nothing like
    /// them. In a real session with "Omar", "Comm", "Panel" and "comms",
    /// "a little bigger" came back "a little Panel", "Okay" became "Omar" and
    /// "the dictionary" became "the Panel". None of these lines says a term.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["WILCO_ASR_TESTS"] != nil))
    func shortTermsLeaveUnrelatedWordsAlone() async throws {
        let store = Self.testStore()
        try await store.install { _ in }
        let terms = ["comms", "Omar", "Comm", "Panel"]
        let recognizer = ParakeetRecognizer(store: store, language: .english, vocabulary: terms)
        // Each of these, in this voice, came back as a term with the
        // rescorer's acoustic rescue on, even without added noise.
        let lines: [(String, String)] = [
            ("Um.", "Samantha"), ("Whisper.", "Samantha"), ("Whisper.", "Karen"),
            ("And audio.", "Daniel"), ("Let's make this a little bigger.", "Karen"),
        ]
        for (line, voice) in lines {
            let text = try await recognizer.recognize(sayClip(line, voice: sayVoice(voice)))?.text ?? ""
            for term in terms {
                #expect(!text.lowercased().contains(term.lowercased()), "\(term) in \"\(text)\" for \"\(line)\" (\(voice))")
            }
        }
    }

    /// A term that is said still comes back spelled the show's way.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["WILCO_ASR_TESTS"] != nil))
    func spokenShortTermIsKept() async throws {
        let store = Self.testStore()
        try await store.install { _ in }
        let recognizer = ParakeetRecognizer(store: store, language: .english, vocabulary: ["Omar", "Panel"])
        let text = try await recognizer.recognize(sayClip("Omar, check the panel please."))?.text ?? ""
        #expect(text.contains("Omar"))
    }

    /// The app's model when installed; otherwise FluidAudio's default cache,
    /// which holds the same files, to avoid a fresh download.
    private static func testStore() -> ParakeetModelStore {
        let store = ParakeetModelStore()
        return store.isInstalled()
            ? store : ParakeetModelStore(directory: AsrModels.defaultCacheDirectory(for: .v3).deletingLastPathComponent())
    }

    // MARK: Preview gate

    @Test func previewWaitsForNoFinal() async {
        let gate = PreviewGate()
        await gate.beginFinal()
        #expect(await gate.tryBeginPreview() == false)
        await gate.endFinal()
        #expect(await gate.tryBeginPreview() == true)
        // One preview at a time.
        #expect(await gate.tryBeginPreview() == false)
        await gate.endPreview()
        #expect(await gate.tryBeginPreview() == true)
    }

    @Test func finalsNeverWaitForAPreview() async {
        let gate = PreviewGate()
        #expect(await gate.tryBeginPreview())
        await gate.beginFinal()
        #expect(await gate.finalsInFlight == 1)
    }

    @Test func aFinalThatThrowsStillEndsOnTheGate() async {
        let store = ParakeetModelStore(directory: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
        let recognizer = ParakeetRecognizer(store: store, language: .english)
        await #expect(throws: ParakeetError.notInstalled) { _ = try await recognizer.recognize([0]) }
        #expect(await store.previewGate.finalsInFlight == 0)
        #expect(await store.previewGate.tryBeginPreview())
    }

    @Test func previewWithoutAModelIsNil() async {
        let store = ParakeetModelStore(directory: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
        let preview = await ParakeetRecognizer(store: store, language: .english).preview([Float](repeating: 0, count: 16_000))
        #expect(preview == nil)
        // The failed preview ended on the gate.
        #expect(await store.previewGate.tryBeginPreview())
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["WILCO_ASR_TESTS"] != nil))
    func previewsASpokenCall() async throws {
        let samples = try sayClip("Standby lighting cue forty two")
        let half = Array(samples.prefix(samples.count / 2))
        let preview = await ParakeetRecognizer(store: Self.testStore(), language: .english).preview(half)
        #expect(preview?.text.isEmpty == false)
    }

    @Test func previewsFollowTheLatencyPicker() {
        func configuration(_ engine: SpeechEngine, _ profile: SpeechLatencyProfile) -> TranscriberConfiguration {
            TranscriberConfiguration(channel: ChannelConfig(name: "A", engine: engine, latencyProfile: profile), show: ShowDocument())
        }
        #expect(ChannelTranscribers.previewInterval(for: configuration(.parakeet, .leadAndCorrect)) == .milliseconds(500))
        #expect(ChannelTranscribers.previewInterval(for: configuration(.parakeet, .single)) == nil)
        #expect(ChannelTranscribers.previewInterval(for: configuration(.whisper, .leadAndCorrect)) == nil)
    }
}
