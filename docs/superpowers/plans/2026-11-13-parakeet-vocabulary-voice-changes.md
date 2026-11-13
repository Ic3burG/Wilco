# Parakeet, Vocabulary and Voice Changes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Parakeet TDT v3 as an app speech engine that honours the show's vocabulary, and mark each transcript line with a per-exchange voice letter (A, B, C…) on every engine, splitting lines where the voice changes.

**Architecture:** Parakeet runs through FluidAudio inside `WilcoTranscription`, reusing `UtteranceChannelTranscriber`; vocabulary is FluidAudio's separate-CTC-encoder rescoring, English channels only. Voice changes are a per-channel `VoiceAnnotator` fed by the transcriber (the ring's only reader): WeSpeaker voiceprints → a pure `VoiceTracker` (letters per exchange) → a pure `LineSplitter` using word timings. Final lines go out in two stages: `.recognized` (rules fire immediately, as today) then `.annotated` (timeline, `.jsonl`, reports).

**Tech Stack:** Swift 6 (strict concurrency), SwiftUI, Swift Testing, FluidAudio 0.18.3 (pinned), WhisperKit, Apple Speech (macOS 26+), `wilco-bench`.

**Spec:** `docs/superpowers/specs/2026-11-13-parakeet-vocabulary-voice-changes-design.md`

## Global Constraints

- Deployment target macOS 15; CI builds with Xcode 26.6. Apple speech APIs need `@available(macOS 26, *)`. FluidAudio supports macOS 14+ (no guards needed for it).
- FluidAudio stays `exact: "0.18.3"`.
- Every existing `.wilco` show and `.jsonl` transcript keeps opening. New fields decode with defaults; nil optional fields are omitted when encoding.
- The audio thread is real-time: no allocation, locking or logging in capture callbacks. `AudioRingBuffer` has one reader, the channel's transcriber.
- Voiceprints (speaker embeddings) are never written to disk, logs or exports.
- 32 channels must keep up on the M1 Max in `wilco-bench` (no dropped audio, ≤ 5% missed, p95 delay and backlog ≤ 3 s).
- Rules fire on the recognised line without waiting for voice analysis.
- Never name or version the reference app anywhere. Say "the reference app" in docs.
- Swift Testing (`@Suite`, `@Test`), not XCTest. Tests needing real models gate on `WILCO_ASR_TESTS` with `.enabled(if:)`.
- Fix warnings; don't silence them.
- Package tests: `cd Packages/WilcoCore && swift test`. App build: `xcodebuild build -project Wilco.xcodeproj -scheme Wilco -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY=""`.
- Commit messages end with the session's `Co-Authored-By` / `Claude-Session` lines.

## Review Focus

1. **A Parakeet model removed in Settings while a channel uses it** → that channel shows "failed: the Parakeet model isn't installed" and others carry on; no crash. Test in Task 2.
2. **Vocabulary terms with digits and punctuation** ("Q5", "LX 42", "D.S.M.") → the vocabulary context builds and boosting runs; nothing throws. Test in Task 3.
3. **A line too short for any voiceprint** (a 0.3 s "Go") → the line still appears, with no letter ("·"), and the tracker's state is unchanged. Tests in Tasks 9 and 11.
4. **More than 26 voices in one exchange** → letters continue AA, AB…; never repeat a letter for a different voice. Test in Task 9.
5. **A report or export from a session where only some channels had voice changes, or an older `.jsonl`** → lines without a letter render exactly as today (no "nil", no empty badge, no "· :" prefix in SRT). Test in Task 15.

---

## Phase A: Parakeet with vocabulary (Tasks 1–6)

Parakeet stays out of the engine picker until Task 4, so it never appears ignoring the show's vocabulary.

### Task 1: `SpeechEngine.parakeet` and tolerant engine decoding

**Files:**
- Modify: `Packages/WilcoCore/Sources/WilcoCore/Model/ChannelConfig.swift:106-113` (enum), `:86` (decode)
- Modify: every `switch` over `SpeechEngine` the compiler flags (`SpeechAssets.swift:89`, `ChannelInspector.swift:202`, `LanguagesSettingsView.swift` `shortName`, `ChannelTranscriber.swift` `make`)
- Modify: `Wilco/Inspector/ChannelInspector.swift:127`
- Test: `Packages/WilcoCore/Tests/WilcoCoreTests/FileFormatTests.swift`

**Interfaces:**
- Produces: `SpeechEngine.parakeet` (raw value `"parakeet"`); `SpeechEngine.selectable: [SpeechEngine]` (static; excludes `.parakeet` until Task 4); `SpeechEngine.platformDefault: SpeechEngine` (`.longForm` on macOS 26+, else `.whisper`).

- [ ] **Step 1: Write the failing tests** in `FileFormatTests`:

```swift
@Test func unknownEngineDecodesAsPlatformDefault() throws {
    let json = #"{"id":"6F9619FF-8B86-D011-B42D-00CF4FC964FF","name":"SM","engine":"quantum"}"#
    let channel = try JSONDecoder().decode(ChannelConfig.self, from: Data(json.utf8))
    #expect(channel.engine == SpeechEngine.platformDefault)
    #expect(channel.name == "SM")
}

@Test func parakeetEngineRoundTrips() throws {
    let channel = ChannelConfig(name: "SM", engine: .parakeet)
    let decoded = try JSONDecoder().decode(ChannelConfig.self, from: JSONEncoder().encode(channel))
    #expect(decoded.engine == .parakeet)
}
```

- [ ] **Step 2: Run** `swift test --filter FileFormatTests` — expect FAIL (`.parakeet` / `platformDefault` undefined).
- [ ] **Step 3: Implement.** Add the case and `platformDefault`. In `ChannelConfig.init(from:)` decode `engine` as `String?` and map with `SpeechEngine(rawValue:) ?? .platformDefault` (missing key stays `.longForm` as today). Add a placeholder arm for `.parakeet` in each flagged switch: `SpeechAssets` treats it like `.whisper` (`.unavailable`, no install); display names "Parakeet" / "Parakeet (open)". `ChannelTranscribers.make` routes `.parakeet` to Whisper until Task 2. Inspector picker iterates `SpeechEngine.selectable`.
- [ ] **Step 4: Run** `swift test` — expect all PASS; run the app build — expect `BUILD SUCCEEDED`.
- [ ] **Step 5: Commit** `Add the Parakeet engine case; unknown engines decode as the default`.

### Task 2: Parakeet in `WilcoTranscription`

**Files:**
- Modify: `Packages/WilcoCore/Package.swift` (FluidAudio product on `WilcoTranscription`; keep on `WilcoBench`)
- Modify: `Packages/WilcoCore/Sources/WilcoCore/Persistence/DataLocations.swift` (add `parakeetModels`)
- Create: `Packages/WilcoCore/Sources/WilcoTranscription/ParakeetModelStore.swift`
- Create: `Packages/WilcoCore/Sources/WilcoTranscription/ParakeetRecognizer.swift`
- Modify: `Packages/WilcoCore/Sources/WilcoTranscription/ChannelTranscriber.swift` (`make`)
- Modify: `Packages/WilcoCore/Sources/WilcoBench/ParakeetEngine.swift` (use the store; delete its `ParakeetModel`/`ParakeetRecognizer`)
- Test: `Packages/WilcoCore/Tests/WilcoTranscriptionTests/ParakeetTests.swift`

**Interfaces:**
- Consumes: `SpeechEngine.parakeet` (Task 1); `UtteranceRecognizer`, `UtteranceChannelTranscriber`, `Recognition` (existing).
- Produces:
  - `DataLocations.parakeetModels: URL` = `root/ParakeetModels`.
  - `public actor ParakeetModelStore` — `init(directory: URL = DataLocations.parakeetModels)`; `nonisolated func isInstalled() -> Bool` (TDT v3 present); `nonisolated func sizeOnDisk() -> Int64?`; `nonisolated func install(progress: @escaping @Sendable (Double) -> Void) async throws` (TDT v3, then the CTC 110M model in Task 3); `nonisolated func remove() throws`; `func manager() async throws -> AsrManager` (loads once; concurrent callers share one load; throws `ParakeetError.notInstalled` when missing).
  - `struct ParakeetRecognizer: UtteranceRecognizer` — `init(store: ParakeetModelStore, language: FluidAudio.Language?)`.
  - `ChannelTranscribers.make(…, whisperModels:, parakeetModels: ParakeetModelStore, …)`.
  - `enum ParakeetLanguages { static func language(for identifier: String) -> FluidAudio.Language? }` — `""` → nil (detect); otherwise match the identifier's language code to `Language.rawValue`.

- [ ] **Step 1: Write the failing tests:**

```swift
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

@Test(.enabled(if: ProcessInfo.processInfo.environment["WILCO_ASR_TESTS"] != nil))
func transcribesASpokenCall() async throws {
    // Render "Standby lighting cue forty two" with `say` at 16 kHz (reuse ClipLibrary.say via a test helper).
    let recognition = try await ParakeetRecognizer(store: ParakeetModelStore(), language: .english).recognize(samples)
    #expect(recognition?.text.lowercased().contains("lighting") == true)
}
```

- [ ] **Step 2: Run** `swift test --filter ParakeetTests` — expect FAIL (types undefined).
- [ ] **Step 3: Implement.** Move the loader logic from `WilcoBench/ParakeetEngine.swift` into `ParakeetModelStore` (`AsrModels.download(to: directory…, version: .v3)` / `AsrModels.load(from:version:)`). `ParakeetRecognizer.recognize` pads to `ASRConstants.minimumRequiredSamples` as now and passes `language:` to `AsrManager.transcribe`. In `make`, `.parakeet` → `UtteranceChannelTranscriber(recognizer: ParakeetRecognizer(store:language:))`. The bench's `parakeet-v3` engine uses a store at FluidAudio's default folder so existing downloads still work. `parakeet-v2` stays in the bench only, keeping its own small loader in `ParakeetEngine.swift` (the store is v3-only).
- [ ] **Step 4: Run** `swift test` and `WILCO_ASR_TESTS=1 swift test --filter ParakeetTests` — expect PASS. Run `swift run -c release wilco-bench --engines parakeet-v3 --channels 1,32` — expect "yes" in Keeps up.
- [ ] **Step 5: Commit** `Move Parakeet into WilcoTranscription as a channel engine`.

### Task 3: Vocabulary boosting for Parakeet (English only)

**Files:**
- Create: `Packages/WilcoCore/Sources/WilcoTranscription/ParakeetVocabulary.swift`
- Modify: `ParakeetModelStore.swift` (install/load CTC 110M; `func ctcModels() async throws -> …`)
- Modify: `ParakeetRecognizer.swift`, `ChannelTranscriber.swift` (`make` passes `configuration.vocabulary`)
- Modify: `Packages/WilcoCore/Sources/WilcoBench/ParakeetEngine.swift` (add `parakeet-v3-vocab`), `BenchRunner.swift` / `ClipLibrary.swift` (scenario vocabulary)
- Test: `Packages/WilcoCore/Tests/WilcoTranscriptionTests/ParakeetTests.swift`

**Interfaces:**
- Consumes: `ParakeetModelStore`, `ParakeetRecognizer` (Task 2); `TranscriberConfiguration.vocabulary`.
- Produces:
  - `enum ParakeetVocabulary { static func applies(language: FluidAudio.Language?, terms: [String]) -> Bool }` — true only for `.english` with at least one non-blank term.
  - `static func thresholds -> VocabularyBoostingSession.Thresholds` — `cbw: 0, minSimilarity: 0.7` (FluidAudio's conservative dictation setting).
  - `ParakeetRecognizer.init(store:language:vocabulary: [String])`.
  - `ClipLibrary.vocabulary: [String]` — the cue words the bench phrases use.

- [ ] **Step 1: Write the failing tests:**

```swift
@Test func vocabularyOnlyForEnglish() {
    #expect(ParakeetVocabulary.applies(language: .english, terms: ["Kinesys"]))
    #expect(!ParakeetVocabulary.applies(language: nil, terms: ["Kinesys"]))
    #expect(!ParakeetVocabulary.applies(language: .french, terms: ["Kinesys"]))
    #expect(!ParakeetVocabulary.applies(language: .english, terms: ["  "]))
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["WILCO_ASR_TESTS"] != nil))
func awkwardTermsBuildAndRun() async throws {
    let recognizer = ParakeetRecognizer(store: ParakeetModelStore(), language: .english,
                                        vocabulary: ["Q5", "LX 42", "D.S.M.", "Kinesys"])
    let recognition = try await recognizer.recognize(sayClip("Standby the Kinesys rig"))
    #expect(recognition?.text.contains("Kinesys") == true)
}
```

- [ ] **Step 2: Run** — expect FAIL.
- [ ] **Step 3: Implement.** Build one `VocabularyBoostingSession` per recognizer (lazily, after the CTC model loads) from the terms with `thresholds`. In `recognize`, when `applies`, call `session.rescore(text:tokenTimings:audioSamples:)` on the TDT result and use its text when a replacement was applied. CTC model folder: `directory/ctc-110m`. `isInstalled()` stays TDT-only; vocabulary on a channel whose CTC model is missing logs a status message once and transcribes without boosting. Bench: `parakeet-v3-vocab` passes `ClipLibrary.vocabulary`.
- [ ] **Step 4: Run** `swift test`, `WILCO_ASR_TESTS=1 swift test --filter ParakeetTests` — expect PASS.
- [ ] **Step 5: Commit** `Boost the show's vocabulary on English Parakeet channels`.

### Task 4: Parakeet in the app

**Files:**
- Modify: `Wilco/Capture/TranscriptionController.swift` (own a `ParakeetModelStore`, pass to `make`)
- Modify: `Wilco/Settings/ModelInstaller.swift` (`Item.parakeet`; share the controller's store via `AppModel`)
- Modify: `Wilco/Settings/LanguagesSettingsView.swift` (Parakeet section; Speech Models rows)
- Modify: `Wilco/Inspector/ChannelInspector.swift` (picker, language menu, vocabulary note)
- Modify: `Packages/WilcoCore/Sources/WilcoTranscription/LanguageCatalog.swift`
- Modify: `Packages/WilcoCore/Sources/WilcoCore/Model/ChannelConfig.swift` (`selectable` now includes `.parakeet`)
- Create: `Wilco/Credits.rtf`
- Modify: `docs/SPEC.md` (engine list, model folder)
- Test: `Packages/WilcoCore/Tests/WilcoTranscriptionTests/LanguageCatalogTests.swift`

**Interfaces:**
- Consumes: `ParakeetModelStore` (Tasks 2–3), `ParakeetVocabulary.applies` (Task 3).
- Produces: `LanguageCatalog.options(for: .parakeet)` = `[.autoDetect]` + one option per `FluidAudio.Language` case (identifier = its raw code, e.g. `"en"`).

- [ ] **Step 1: Write the failing test:**

```swift
@Test func parakeetOffersDetectPlusItsLanguages() async {
    let options = await LanguageCatalog.options(for: .parakeet)
    #expect(options.first == .autoDetect)
    #expect(options.contains { $0.identifier == "en" })
    #expect(options.count == FluidAudio.Language.allCases.count + 1)
}
```

- [ ] **Step 2: Run** — expect FAIL.
- [ ] **Step 3: Implement.**
  - Settings → Languages: "Parakeet Model" section after the Whisper one, with status / Install / Remove / size (same `status(for:)` helper). Footer: "Parakeet TDT v3 runs on the Neural Engine. One model serves every Parakeet channel and detects 25 European languages. Vocabulary applies to English channels. ~600 MB with the vocabulary model." Speech Models rows for Parakeet channels show this model's status.
  - Inspector: engine picker uses `selectable` (now with Parakeet). Choosing Parakeet with an empty locale sets `"en"`. When engine is Parakeet and `!ParakeetVocabulary.applies(…)` but the show has vocabulary, show the secondary text "Vocabulary applies to English channels only." Translate to English stays Whisper-only.
  - `Credits.rtf`: FluidAudio (Apache-2.0), WhisperKit (MIT), NVIDIA Parakeet TDT 0.6B v3 and Parakeet CTC 110M (CC-BY-4.0, with model links), WeSpeaker model (licence from its model card; added in Task 10).
- [ ] **Step 4: Run** `swift test` and the app build — expect PASS / `BUILD SUCCEEDED`.
- [ ] **Step 5: Commit** `Offer Parakeet in the app with its model in Languages settings`.

### Task 5: Measure vocabulary at 32 channels (gate)

**Files:**
- Create: `docs/benchmarks/<date>-m1-max-say-parakeet-vocab.md` / `.json`

- [ ] **Step 1: Run** `swift run -c release wilco-bench --engines parakeet-v3,parakeet-v3-vocab --channels 1,8,16,32` (Mac quiet, reference app closed).
- [ ] **Step 2: Decide.** If `parakeet-v3-vocab` keeps up at 32 → skip Task 6. If not → do Task 6. Record the numbers and the decision in the benchmark file and `docs/PROGRESS.md`.
- [ ] **Step 3: Commit** `Benchmark Parakeet vocabulary at 32 channels`.

### Task 6 (only if Task 5 fails): Per-channel vocabulary switch

**Files:**
- Modify: `ChannelConfig.swift` (`usesVocabulary: Bool`, decoded default `true`), `ChannelTranscriber.swift` (`TranscriberConfiguration.vocabulary` empty when off), `ChannelInspector.swift` (toggle "Use vocabulary", Parakeet only)
- Test: `FileFormatTests.swift`, `TranscriptionTests.swift`

- [ ] **Step 1: Write failing tests:** a channel JSON without `usesVocabulary` decodes `true`; `TranscriberConfiguration(channel:show:)` with `usesVocabulary == false` on a Parakeet channel has `vocabulary == []` while Apple/Whisper channels are unaffected.
- [ ] **Step 2: Run** — FAIL. **Step 3: Implement.** New Parakeet channels default `usesVocabulary = false`; the help text names the cost ("Uses more processing; turn on for calling lines").
- [ ] **Step 4: Run** tests + app build — PASS. **Step 5: Commit** `Make Parakeet vocabulary a per-channel switch`.

---

## Phase B: Voice changes (Tasks 7–15)

### Task 7: Data model for voices and two-stage lines

**Files:**
- Modify: `Packages/WilcoCore/Sources/WilcoCore/Model/TranscriptSegment.swift`
- Modify: `Packages/WilcoCore/Sources/WilcoCore/Transcription/TranscriptTimeline.swift` (`TranscriptionEvent`)
- Modify: `ChannelConfig.swift` (`detectsVoiceChanges`), `ShowDocument.swift` (`voiceChanges`)
- Create: `Packages/WilcoCore/Sources/WilcoCore/Model/VoiceChangeSettings.swift`
- Modify: `Packages/WilcoCore/Sources/WilcoCore/Automation/TemplateContext.swift` (`{voice}`)
- Modify: `docs/SPEC.md` (segment fields, show fields, `{voice}`)
- Test: `FileFormatTests.swift`, `AutomationTests.swift`

**Interfaces:**
- Produces:
  - `TranscriptSegment.voice: String?`, `TranscriptSegment.exchange: Int?` (encoded only when non-nil).
  - `TranscriptionEvent.lineID: UUID` (default `UUID()`), `TranscriptionEvent.stage: LineStage`, where `public enum LineStage: Equatable, Sendable { case complete; case recognized; case annotated(voice: String?, exchange: Int?) }` (default `.complete`).
  - `public struct VoiceChangeSettings: Codable, Equatable, Sendable { var threshold: Double = 0.5; var exchangeGap: Double = 20; var shortLine: Double = 1.0; static let standard }` — `threshold` is cosine distance (placeholder until Task 12 tunes it).
  - `ShowDocument.voiceChanges: VoiceChangeSettings` (decoded default `.standard`); `ChannelConfig.detectsVoiceChanges: Bool` (default `false`); `TranscriberConfiguration.voiceChanges: VoiceChangeSettings?` (nil when the channel has it off).
  - `TemplateContext.voice: String` (default `""`), placeholder `{voice}`.

- [ ] **Step 1: Write the failing tests:**

```swift
@Test func segmentWithoutVoiceEncodesExactlyAsBefore() throws {
    let segment = TranscriptSegment(channelID: UUID(), text: "Go", timestamp: .now, sessionOffset: 1, isFinal: true)
    let json = String(decoding: try WilcoJSON.encoder.encode(segment), as: UTF8.self)
    #expect(!json.contains("voice") && !json.contains("exchange"))
}

@Test func existingTranscriptFixturesStillDecode() throws { /* decode every Fixtures/*.jsonl line; voice == nil */ }

@Test func showWithoutVoiceSettingsDecodesDefaults() throws {
    // existing fixture show → voiceChanges == .standard, every channel detectsVoiceChanges == false
}

@Test func voicePlaceholderExpands() {
    let context = TemplateContext(text: "Go", channel: "SM", keyword: "", date: .now, offset: 0, voice: "B")
    #expect(context.expand("{channel}/{voice}") == "SM/B")
}
```

- [ ] **Step 2: Run** — FAIL. **Step 3: Implement** (use the encoder `TranscriptWriter` uses; custom `encode(to:)` with `encodeIfPresent`). **Step 4: Run** `swift test` + app build — PASS.
- [ ] **Step 5: Commit** `Add voice letters, exchange numbers and two-stage lines to the model`.

### Task 8: Two-stage line handling (rules first)

**Files:**
- Modify: `TranscriptTimeline.swift` (`apply`)
- Modify: `Packages/WilcoCore/Sources/WilcoCore/Automation/AutomationEvaluator.swift` (keyword assignment helper)
- Modify: `Wilco/AppModel.swift:239-266` (`apply(_:)`)
- Modify: `Packages/WilcoCore/Sources/WilcoBench/BenchRunner.swift`, `Scorer.swift` (count a line once; "final delay" = `.complete` or `.recognized` arrival; add display delay = `.annotated` arrival)
- Test: `TranscriptionLogicTests.swift`, `AutomationTests.swift`

**Interfaces:**
- Consumes: `LineStage`, `lineID` (Task 7).
- Produces:
  - `TranscriptTimeline.apply`: `.complete` → as today; `.recognized` → sets the channel's volatile text to the line (no segment); `.annotated(voice:exchange:)` → clears volatile, appends a segment with `voice`/`exchange`.
  - `AutomationEvaluator.keywords(_ matched: [String], in text: String) -> [String]` — the matched phrases that occur in `text` (case-insensitive).
  - AppModel: rules run on `.complete` and `.recognized`; `.annotated` segments get highlights per piece and `matchedKeywords` from the recognised line's matches (kept by `lineID`, first piece gets any phrase found in no piece); writer appends `.complete` and `.annotated` only. `TemplateContext.voice` is `""` at rule time.

- [ ] **Step 1: Write failing tests:**

```swift
@Test func recognizedLineShowsAsInProgressUntilAnnotated() {
    var timeline = TranscriptTimeline()
    let id = UUID(), channel = UUID()
    #expect(timeline.apply(.init(channelID: channel, text: "Standby LX 42", isFinal: true, sessionOffset: 5, confidence: nil, lineID: id, stage: .recognized), at: .now) == nil)
    #expect(timeline.volatile[channel] == "Standby LX 42")
    let first = timeline.apply(.init(channelID: channel, text: "Standby LX 42", isFinal: true, sessionOffset: 5, confidence: nil, lineID: id, stage: .annotated(voice: "A", exchange: 1)), at: .now)
    #expect(first?.voice == "A" && timeline.volatile[channel] == nil)
}

@Test func keywordsFollowThePieceThatSaidThem() {
    #expect(AutomationEvaluator.keywords(["go", "standby"], in: "LX 42 go") == ["go"])
}
```

- [ ] **Step 2: Run** — FAIL. **Step 3: Implement.** **Step 4: Run** `swift test` + app build — PASS.
- [ ] **Step 5: Commit** `Fire rules on the recognised line; store the voice-annotated one`.

### Task 9: `VoiceTracker`

**Files:**
- Create: `Packages/WilcoCore/Sources/WilcoCore/Transcription/VoiceTracker.swift`
- Test: `Packages/WilcoCore/Tests/WilcoCoreTests/VoiceTrackerTests.swift`

**Interfaces:**
- Consumes: `VoiceChangeSettings` (Task 7).
- Produces:
  - `public struct Voiceprint: Sendable { var vector: [Float]; var start: Double; var end: Double }` (session offsets; vector L2-normalised).
  - `public struct VoicePiece: Equatable, Sendable { var start: Double; var end: Double; var voice: String?; var exchange: Int }`.
  - `public struct VoiceTracker: Sendable { init(settings: VoiceChangeSettings); mutating func assign(_ prints: [Voiceprint], lineStart: Double, lineEnd: Double) -> [VoicePiece] }`.
  - `static func letter(_ index: Int) -> String` — 0 → "A", 25 → "Z", 26 → "AA", 27 → "AB".

The algorithm (the signature doesn't determine it):

```
exchange: if lineStart - lastLineEnd > settings.exchangeGap → exchange += 1, forget voices
change points: between neighbouring prints whose cosine distance > threshold,
               ignoring a change that would leave a piece shorter than 0.8 s
per piece: mean of its prints (re-normalised), compared with each known voice's running mean
  nearest distance ≤ threshold                   → that letter; fold the print into its mean
  piece shorter than shortLine:
     nearest distance ≤ threshold × 1.25         → that letter (mean unchanged)
     else                                        → voice nil
  else                                           → next letter, new voice
no prints at all                                 → one piece, voice nil, voices unchanged
lastLineEnd = lineEnd
```

- [ ] **Step 1: Write failing tests** (synthetic unit vectors; `print(v, t0, t1)` helper):
  - `twoVoicesAlternatingGetTwoLetters` — A, B, A across three lines.
  - `thirdVoiceGetsC` — A, B, C, A.
  - `silenceLongerThanGapRestartsLetters` — line at t=0 voice X → "A"; line at t=30 voice Y → "A", exchange 2.
  - `changeMidLineMakesTwoPieces` — prints X,X,X,Y,Y,Y over 0–3 s → pieces [A 0–1.5, B 1.5–3].
  - `briefBlipDoesNotSplit` — X,X,X,Y,X,X with Y at 0.5 s → one piece.
  - `shortLineMatchesLooselyOrStaysUnknown` — 0.6 s line near A → "A"; 0.6 s line far from all → nil, and the next long line from that far voice gets "B", not "C".
  - `lineWithNoPrintsHasNoLetterAndChangesNothing`.
  - `lettersContinuePastZ` — 28 orthogonal voices → last two "AA", "AB"; `letter(26) == "AA"`.
- [ ] **Step 2: Run** `swift test --filter VoiceTrackerTests` — FAIL. **Step 3: Implement.** **Step 4: Run** — PASS.
- [ ] **Step 5: Commit** `Add VoiceTracker: letters per exchange from voiceprints`.

### Task 10: Voiceprints from FluidAudio

**Files:**
- Create: `Packages/WilcoCore/Sources/WilcoTranscription/VoiceprintExtractor.swift`
- Modify: `DataLocations.swift` (`voiceModels`)
- Test: `Packages/WilcoCore/Tests/WilcoTranscriptionTests/VoiceprintTests.swift`

**Interfaces:**
- Consumes: `Voiceprint` (Task 9).
- Produces:
  - `public protocol VoiceprintExtractor: Sendable { func prepare() async throws; func voiceprints(of samples: [Float], startingAt offset: Double) async throws -> [Voiceprint] }` — 16 kHz mono in; windows of 1.5 s every 0.5 s; audio shorter than 0.5 s → `[]`.
  - `public actor WeSpeakerVoiceprints: VoiceprintExtractor` — `init(directory: URL = DataLocations.voiceModels)`, `nonisolated func isInstalled() -> Bool`, `nonisolated func install(progress:) async throws`, `nonisolated func remove() throws`. One shared instance per app, as with the speech model stores.

- [ ] **Step 1: Write failing tests:**
  - `shortAudioGivesNoPrints` (no model needed; 0.3 s of samples → `[]` before touching the model).
  - ASR-gated `sameVoiceIsCloserThanDifferentVoices`: two `say` phrases in Samantha and one in Daniel; mean print distance same-voice < different-voice by at least 0.1.
- [ ] **Step 2: Run** — FAIL.
- [ ] **Step 3: Implement.** Use FluidAudio's WeSpeaker embedding model from the diarizer model set. `EmbeddingExtractor.getEmbeddings` takes a fixed 10 s window (`[3, 160_000]`) plus activity masks: pack up to three 1.5 s windows per call (one per mask row) and mask the rest, or use a lighter embedding entry point if the 0.18.3 diarizer exposes one. Measure ms per window on the ANE and note it in the test output. Add the WeSpeaker licence to `Credits.rtf`.
- [ ] **Step 4: Run** `swift test`, `WILCO_ASR_TESTS=1 swift test --filter VoiceprintTests` — PASS.
- [ ] **Step 5: Commit** `Extract voiceprints with FluidAudio's WeSpeaker model`.

### Task 11: `VoiceAnnotator` in every transcriber (whole-line letters)

**Files:**
- Create: `Packages/WilcoCore/Sources/WilcoTranscription/VoiceAnnotator.swift`
- Create: `Packages/WilcoCore/Sources/WilcoCore/Audio/AudioHistory.swift`
- Modify: `UtteranceChannelTranscriber.swift`, `WhisperChannelTranscriber.swift`, `AppleChannelTranscriber.swift`, `ChannelTranscriber.swift` (`make` takes `voiceprints: (any VoiceprintExtractor)?`)
- Modify: `Wilco/Capture/TranscriptionController.swift` (shared `WeSpeakerVoiceprints`)
- Test: `Packages/WilcoCore/Tests/WilcoCoreTests/AudioPrimitivesTests.swift`, `Packages/WilcoCore/Tests/WilcoTranscriptionTests/VoiceAnnotatorTests.swift`

**Interfaces:**
- Consumes: `VoiceTracker` (9), `VoiceprintExtractor` (10), `LineStage`/`lineID` (7), `TranscriberConfiguration.voiceChanges` (7).
- Produces:
  - `public struct AudioHistory: Sendable { init(sampleRate: Double = 16_000, seconds: Double = 30); mutating func append(_ samples: [Float], endingAt offset: Double); func samples(from: Double, to: Double) -> [Float] }` — bounded; a span older than the history returns what is left.
  - `public actor VoiceAnnotator { init(settings: VoiceChangeSettings, extractor: any VoiceprintExtractor); func annotate(_ line: TranscriptionEvent, audio: [Float], lineStart: Double, lineEnd: Double) async -> [TranscriptionEvent] }` — returns `.annotated` events (one per piece; for now always one: the whole line with the letter of its longest piece). Extractor failure → one event with `voice: nil`.
  - Transcribers: with `voiceChanges != nil`, emit `.recognized` at once, then `await annotator.annotate(…)` and emit its events; otherwise emit `.complete` exactly as today. Utterance/Whisper pass the utterance audio. Apple keeps an `AudioHistory` (a second `SampleRateConverter.whisper()` in `feed`, only when enabled) and passes `history.samples(from: start, to: end)` for each final result.

- [ ] **Step 1: Write failing tests:**
  - `AudioHistory`: `keepsTheLastThirtySeconds`, `spanBeforeHistoryReturnsWhatRemains`.
  - `annotatorGivesEveryLineALetterAndKeepsItsID` (fake extractor returning fixed prints: two lines, two voices → "A", "B"; `lineID` preserved).
  - `failingExtractorStillDeliversTheLine` → one `.annotated(voice: nil, …)` event with the original text.
  - `restartedChannelStartsAFreshExchange` (new annotator → first voice "A").
  - `voiceChangesOffEmitsCompleteOnly` (UtteranceChannelTranscriber with a fake recognizer and `voiceChanges: nil` → only `.complete`).
- [ ] **Step 2: Run** — FAIL. **Step 3: Implement.** **Step 4: Run** `swift test` + app build — PASS.
- [ ] **Step 5: Commit** `Annotate final lines with voice letters on every engine`.

### Task 12: Voice scoring in `wilco-bench`, 32-channel gate, defaults

**Files:**
- Modify: `Packages/WilcoCore/Sources/WilcoBench/BenchRunner.swift` (`BenchClip.voice: Int`), `ClipLibrary.swift` (voice index per clip; corpus `name.txt` lines may start with `A: `), `Scenario.swift` (`generateConversations`), `Scorer.swift`, `BenchReport.swift`, `BenchEngine.swift` (`-voices` variants), `Sources/wilco-bench/main.swift` (`--conversation`)
- Modify: `docs/BENCHMARK.md`
- Test: `Packages/WilcoCore/Tests/WilcoBenchTests/BenchLogicTests.swift`

**Interfaces:**
- Consumes: `.recognized`/`.annotated` events (7, 11).
- Produces:
  - `Scenario.generateConversations(channels:duration:seed:clips:)` — per channel, exchanges of 2–5 turns among 2–4 voices, 0.1–0.8 s between turns (some back-to-back, i.e. merged by the segmenter), returning voices, 25–40 s quiet between exchanges.
  - Scorer: `missedChanges`, `falseChanges` (turn boundaries vs. annotated pieces, ±0.5 s), `letterAccuracy` (returning voice gets its earlier letter), `displayDelay` p50/p95 alongside the existing final delay.
  - Engines `parakeet-v3-voices`, `apple-longform-voices`, `whisper-base-voices`.

- [ ] **Step 1: Write failing tests:** conversation scenario is deterministic for a seed and contains at least one back-to-back turn and one returning voice; scorer on a hand-built result counts 1 missed, 1 false, letter accuracy 2/3.
- [ ] **Step 2: Run** — FAIL. **Step 3: Implement.** **Step 4: Run** tests — PASS.
- [ ] **Step 5: Measure.** `swift run -c release wilco-bench --conversation --engines parakeet-v3,parakeet-v3-voices,apple-longform,apple-longform-voices,whisper-base,whisper-base-voices --channels 1,8,16,32`. Try thresholds 0.4 / 0.5 / 0.6 (a `--voice-threshold` option) and set `VoiceChangeSettings.standard` to the best. Save the report to `docs/benchmarks/`. If every `-voices` engine keeps up at 32 → `detectsVoiceChanges` defaults to on for new channels (decoded default stays `false` for existing shows); otherwise leave it off and note the limit in PROGRESS.md.
- [ ] **Step 6: Commit** `Score voice changes in wilco-bench; tune the defaults`.

### Task 13: Word timings and `LineSplitter`

**Files:**
- Create: `Packages/WilcoCore/Sources/WilcoCore/Transcription/LineSplitter.swift`
- Modify: `UtteranceChannelTranscriber.swift` (`Recognition.words`), `ParakeetRecognizer.swift`, `WhisperChannelTranscriber.swift`, `AppleChannelTranscriber.swift`, `VoiceAnnotator.swift`
- Test: `Packages/WilcoCore/Tests/WilcoCoreTests/LineSplitterTests.swift`, `VoiceAnnotatorTests.swift`

**Interfaces:**
- Consumes: `VoicePiece` (9), `VoiceAnnotator` (11).
- Produces:
  - `public struct TimedWord: Equatable, Sendable { var text: String; var start: Double; var end: Double }` (session offsets).
  - `Recognition.words: [TimedWord]` (default `[]`); `VoiceAnnotator.annotate(_:audio:lineStart:lineEnd:words:)`.
  - `public enum LineSplitter { static func split(words: [TimedWord], text: String, pieces: [VoicePiece]) -> [(text: String, start: Double, voice: String?, exchange: Int)] }` — each change goes at the word boundary nearest the change time; a piece that ends up with no words merges into its neighbour; empty `words` or one piece → the whole `text` with the longest piece's voice.
  - Word sources: Parakeet `ASRResult.tokenTimings` (a token starting with `▁` starts a word; offsets + utterance start); Whisper `DecodingOptions(wordTimestamps: true, withoutTimestamps: false)` only when voice changes are on; Apple `SpeechTranscriber` `attributeOptions: [.audioTimeRange]` and each run's `audioTimeRange` (macOS 26 guard, existing).

- [ ] **Step 1: Write failing tests:**
  - `splitsAtTheWordNearestTheChange` — words "Standby"(0–0.5) "LX"(0.5–0.8) "42"(0.8–1.2) "Standing"(1.6–2.0) "by"(2.0–2.3), pieces A 0–1.4, B 1.4–2.3 → `["Standby LX 42" A, "Standing by" B]`, starts 0 and 1.6.
  - `noWordsKeepsTheLineWhole` — longest piece's voice.
  - `pieceWithoutWordsMergesIntoNeighbour`.
  - Annotator: two pieces + words → two `.annotated` events with the same `lineID`, ascending `sessionOffset`.
  - ASR-gated per engine: a two-voice `say` clip with no pause comes back as two lines with different letters.
- [ ] **Step 2: Run** — FAIL. **Step 3: Implement.** **Step 4: Run** `swift test`, ASR tests, app build — PASS. Re-run the Task 12 bench at 32 channels; confirm still keeps up.
- [ ] **Step 5: Commit** `Split lines where the voice changes, using word timings`.

### Task 14: Voice changes in the app UI

**Files:**
- Modify: `Wilco/Transcript/TranscriptView.swift` (`TranscriptRow` gains `voice: String?`; turn spacing)
- Modify: `Wilco/Inspector/ChannelInspector.swift` (toggle "Mark voice changes")
- Modify: `Wilco/Settings/LanguagesSettingsView.swift` ("Voice Changes" section)
- Modify: `Wilco/Settings/ModelInstaller.swift` (`Item.voiceModel`)

**Interfaces:**
- Consumes: `TranscriptSegment.voice/exchange` (7), `ShowDocument.voiceChanges` (7), `WeSpeakerVoiceprints` install/remove (10).

- [ ] **Step 1: Implement the row.** After the time column, a fixed-width monospaced letter badge (`·` when nil on a voice-change channel; nothing at all for channels with the feature off). A row whose letter differs from the previous row on the same channel gets extra top padding (a visible new turn). Channel tint unchanged.
- [ ] **Step 2: Implement settings.** Section "Voice Changes": slider "Telling voices apart" with ends "Stricter" / "Looser" mapped to `threshold` 0.3…0.7 and the number shown; stepper "New exchange after" 5…60 s for `exchangeGap`; "Restore Defaults" sets `.standard`; the voice model's Install/Remove row. Footer: "Letters mark who is speaking within one exchange, not who they are. Voiceprints are kept in memory only and never saved."
- [ ] **Step 3: Implement the toggle** in the Inspector with help "Letters each line by voice: A, B, C… Starts again after a silence." Disabled with the reason when the voice model isn't installed.
- [ ] **Step 4: Run** the app build — `BUILD SUCCEEDED`; launch and check a channel with and without the feature (see `run` skill), then ask the user to verify in a real show.
- [ ] **Step 5: Commit** `Show voice letters in the transcript; add voice change settings`.

### Task 15: Letters in reports and exports

**Files:**
- Modify: `Packages/WilcoCore/Sources/WilcoCore/Report/ShowReport.swift` (`Message.voice`), `ShowReportHTML.swift`, `SubtitleExport.swift`
- Modify: `docs/SPEC.md` (report and subtitle formats)
- Test: `Packages/WilcoCore/Tests/WilcoCoreTests/ShowReportTests.swift`

**Interfaces:**
- Consumes: `TranscriptSegment.voice` (7).
- Produces: `ShowReport.Message.voice: String?`; HTML chat-log and channel views render a letter badge (class `voice`) when non-nil; SRT/VTT cue text is `"\(voice): \(text)"` when non-nil, else `text`.

- [ ] **Step 1: Write failing tests:**
  - `mixedSessionRendersLettersOnlyWhereSet` — two channels, one with voices: HTML contains `class="voice">B<` for the voiced line and no `voice` element for the other; SRT has `B: Lighting standing by` and the other line unprefixed; no "nil" anywhere.
  - `olderTranscriptRendersAsBefore` — rendering the existing fixture `.jsonl` gives byte-identical HTML/SRT/VTT to the output before this task (capture it first into the test as the expected string or a snapshot fixture).
- [ ] **Step 2: Run** — FAIL. **Step 3: Implement.** **Step 4: Run** `swift test`, and `WILCO_EXPORT_DIR=… swift test --filter ShowReportTests` to eyeball the exports — PASS.
- [ ] **Step 5: Commit** `Show voice letters in reports and subtitle exports`.

---

## End of work

- [ ] Append a dated section to `docs/PROGRESS.md` (features, fixes, tooling, benchmark numbers, next steps: tune on real comms with `--corpus` speaker marks). "Tested" for automated checks; "verified" only after the user tries it in the app.
- [ ] Update the README status table rows for speech engines and voice changes.
- [ ] Commit and push to `main`.
