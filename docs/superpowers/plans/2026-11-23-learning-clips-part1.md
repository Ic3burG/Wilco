# Learning from Shows, Part 1 (Clips and Labels) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When switched on, each session keeps short clips of unclear lines and exchanges; after the show the app labels them with local models; the Review shows per-channel accuracy on those clips and its trend; `wilco-bench --real-show` scores engines on them.

**Architecture:** Pure logic (file formats, clip selection, agreement, voice grouping, accuracy, scheduling) goes in `WilcoCore/Learning` and `WilcoCore/Report/Review`. Model-facing pieces (the clip keeper actor, voters, diarizers, the labeller) go in `WilcoTranscription/Learning`. The app adds a Settings tab, wiring in `AppModel`, and a `LearningController` that runs labelling when no capture is running. Clips reach the keeper through a `ClipTap` on `AudioSource`, beside the existing `DiagnosticsTap`, and are offered from `deliverFinalLine`, which every engine already calls off the real-time thread.

**Tech Stack:** Swift 6 (strict concurrency), Swift Testing, SwiftUI, FluidAudio 0.18.3 (Parakeet Ultra, offline diarizer, offline Sortformer), WhisperKit, Apple Speech (`SpeechAnalyzer`, macOS 26+).

**Spec:** `docs/superpowers/specs/2026-11-23-real-show-clips-design.md` (sections 1, 2, 3 "Accuracy per channel", 5, Deleting). Part 1 only: no Names-to-add/fix-up cards, no `fixUps`, no `heard`, no Check Clips.

## Global Constraints

- Work in a git worktree on branch `learning-clips` (other sessions commit to this checkout); merge to `main` when the whole plan passes.
- Deployment target macOS 15. Apple speech code needs `@available(macOS 26, *)`. CI builds with Xcode 26.6: nothing may need the macOS 27 SDK.
- Swift 6 language mode, strict concurrency. Fix warnings; don't silence them.
- Never allocate, lock or log in capture callbacks. All new work runs in transcriber pumps, actors or background tasks.
- Existing `.jsonl`, `.wilco`, `.diagnostics`, model folders and preferences open unchanged. Part 1 adds no fields to the show or the transcript.
- Sessions are `.jsonl` files only; the `.clips` folder must never be listed as a session.
- Clips are real voices: never commit them, never quote clip or label text in docs, commits or bench output. Bench output for real-show runs holds numbers only.
- Tests use Swift Testing (`@Suite`, `@Test`). Tests that need real models gate on `WILCO_ASR_TESTS`.
- Never name or version the reference app anywhere.
- Preference key: `learning.keepClips` (Bool, default false). Read once at capture start.
- Thresholds (from the spec): unclear = below the channel's running 25th percentile once it has 20 lines, below 0.75 before; nil confidence is unclear. Exchange = 3–12 back-to-back lines, each starting within 10 s of the previous line's end. Skip lines under 0.5 s or 19.5 s and longer. Caps 100 unclear, 20 exchanges per session. Keeper queue limit 32. Manifest save interval 5 s. Labelling starts 120 s after capture stops. Accuracy needs ≥10 scored clips per channel. Exchange gaps capped at 3 s in the bench.

## Review Focus

1. **Capture starts while labelling runs.** Labelling must stop between clips and keep what it finished; the next run resumes. Pinned by `labellerStopsWhenCancelledAndResumes` (Task 10) and `scheduleNeverRunsWhileCapturing` (Task 11).
2. **A clip write fails (disk full, folder removed).** The keeper must keep accepting offers without throwing or blocking transcription. Pinned by `keeperSurvivesAnUnwritableFolder` (Task 4).
3. **The app quits mid-capture.** WAVs may exist with no manifest entry, or entries may point at missing WAVs. Labelling must ignore both. Pinned by `labellerIgnoresStrayFilesAndMissingAudio` (Task 10).
4. **A restart within 2 minutes of stopping.** The old session's labelling must not start during the new capture. Pinned by `scheduleWaitsTwoMinutesAfterStopping` (Task 11).
5. **An Apple line longer than the 30 s audio history.** The audio comes back empty and must be skipped, not saved as an empty clip. Pinned by `skipsEmptyAndOutOfRangeAudio` (Task 3).

---

### Task 1: Move word error rate into WilcoCore

The app now needs the normaliser and word error rate (agreement, accuracy). Move them; don't change behaviour.

**Files:**
- Move: `Packages/WilcoCore/Sources/WilcoBench/WordErrorRate.swift` → `Packages/WilcoCore/Sources/WilcoCore/Learning/WordErrorRate.swift`
- Move tests of `TranscriptNormalizer`/`WordErrorRate` out of `Tests/WilcoBenchTests/BenchLogicTests.swift` and `LongTalkTests.swift` into `Tests/WilcoCoreTests/WordErrorRateTests.swift`

**Interfaces:**
- Produces: `WilcoCore.TranscriptNormalizer.words(_:) -> [String]`, `WilcoCore.WordErrors` (Codable, `+`, `rate`, `errors`, `referenceWords`), `WilcoCore.WordErrorRate.compare(reference:hypothesis:) -> WordErrors`. Same names and access as today (`TranscriptNormalizer.spelled` stays internal; its tests use `@testable import`).

- [ ] **Step 1:** `git mv` the source file; move the tests verbatim into `WordErrorRateTests.swift` with `@testable import WilcoCore`. Fix imports in `Scorer.swift` (it already imports WilcoCore).
- [ ] **Step 2:** Run `cd Packages/WilcoCore && swift test`. Expected: all suites pass, same test count as before.
- [ ] **Step 3:** Commit `Move word error rate into WilcoCore`.

---

### Task 2: Clip and label files

**Files:**
- Create: `Packages/WilcoCore/Sources/WilcoCore/Learning/ClipFiles.swift`, `.../Learning/WAV.swift`
- Test: `Packages/WilcoCore/Tests/WilcoCoreTests/ClipFilesTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public enum ClipKind: String, Codable, Sendable { case unclear, exchange }
  public struct ClipRecord: Codable, Equatable, Sendable, Identifiable {
      public var id: UUID; public var channel: UUID; public var kind: ClipKind
      public var sessionOffset: Double; public var duration: Double; public var confidence: Double?
      public var engine: String          // SpeechEngine raw value
      public var whisperModel: String?   // WhisperModel raw value, Whisper channels only
      public var exchange: Int?          // shared by an exchange's clips, numbered from 1 per session
  }
  public struct ClipManifest: Codable, Equatable, Sendable { public var version = 1; public var clips: [ClipRecord] = []; public var dropped = 0 }
  public enum WordsVerdict: String, Codable, Sendable { case agreed, disputed, checked, notEnoughVoters }
  public enum VoiceVerdict: String, Codable, Sendable { case agreed, disputed }
  public struct ClipLabel: Codable, Equatable, Sendable {
      public var clip: UUID; public var words: WordsVerdict; public var text: String?
      public var candidates: [String: String]; public var voice: VoiceVerdict?; public var speaker: Int?
      public var checked: String?        // part 3 fills it; part 1 only decodes and keeps it
      public var answer: String? { checked ?? (words == .agreed ? text : nil) }
  }
  public struct ClipLabels: Codable, Equatable, Sendable { public var version = 1; public var voters: [String: String] = [:]; public var clips: [ClipLabel] = []; public var finished = false }
  public enum ClipsFolder {
      public static let fileExtension = "clips"
      public static func url(forTranscript: URL) -> URL            // "Session … .clips", beside it
      public static func audioURL(for id: UUID, in folder: URL) -> URL   // "<uuid>.wav"
      public static func loadManifest(in folder: URL) -> ClipManifest?
      public static func loadLabels(in folder: URL) -> ClipLabels?
      public static func save(_ manifest: ClipManifest, in folder: URL) throws   // atomic, creates folder
      public static func save(_ labels: ClipLabels, in folder: URL) throws
      public static func totalSize(in transcripts: URL) -> Int64
      public static func deleteAll(in transcripts: URL) throws
      /// Transcripts whose `.clips` folder has a manifest with clips and no
      /// labels finished with exactly `voters`. Folders with no `.jsonl` are skipped.
      public static func needingLabels(in transcripts: URL, voters: [String: String]) -> [URL]
  }
  public enum WAV {
      public static func encode(_ samples: [Float], sampleRate: Int = 16_000) -> Data  // mono 16-bit PCM, clamped
      public static func decode(_ data: Data) throws -> (samples: [Float], sampleRate: Int)
  }
  ```

- [ ] **Step 1: Write the failing tests** in `ClipFilesTests.swift`:
  - `clipsFolderSitsBesideTheTranscript`: `url(forTranscript: …/"Session 2026-11-21 1720-04.jsonl")` ends with `"Session 2026-11-21 1720-04.clips"`, same parent.
  - `manifestAndLabelsRoundTrip`: save then load equal values; a labels file with `"checked": "x"` decodes with `answer == "x"`.
  - `wavRoundTripsWithinOneStep`: encode `[0, 0.5, -0.5, 1, -1, 2]` and decode: sample rate 16 000, 6 samples, each within `1/32767` of the input clamped to ±1. The first 4 bytes are `"RIFF"`, bytes 8–11 `"WAVE"`.
  - `wavRejectsJunk`: `decode(Data("hello".utf8))` throws.
  - `needingLabelsSkipsOrphansFinishedAndEmpty`: in a temp folder, session A (`.jsonl` + manifest with 1 clip, no labels) is listed; B (`.jsonl` + labels `finished: true`, same voters) isn't; C (`.clips` with no `.jsonl`) isn't; D (labels finished with different voters) is; E (manifest with 0 clips) isn't.
  - `deleteAllRemovesOnlyClipsFolders`: `.jsonl` and `.diagnostics` stay; every `.clips` goes; `totalSize` is 0 afterwards and was > 0 before.
  - `sessionsListIgnoresClipsFolders`: `SessionHistory.summaries(in:candidates:)` on a folder with one session and its `.clips` folder returns 1 summary.
- [ ] **Step 2:** Run `swift test --filter ClipFilesTests`. Expected: FAIL (types not defined).
- [ ] **Step 3:** Implement. JSON with `WilcoJSON`'s encoder/decoder settings (see `WilcoJSON.swift`); save with `.atomic`.
- [ ] **Step 4:** Run `swift test --filter ClipFilesTests`. Expected: PASS.
- [ ] **Step 5:** Commit `Clip and label files`.

---

### Task 3: Choosing which lines to keep

A pure state machine. The keeper (Task 4) holds audio; this decides.

**Files:**
- Create: `Packages/WilcoCore/Sources/WilcoCore/Learning/ClipSelector.swift`
- Test: `Packages/WilcoCore/Tests/WilcoCoreTests/ClipSelectorTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public enum ClipThresholds {
      public static let unclearPercentile = 0.25, warmupLines = 20, warmupConfidence = 0.75
      public static let exchangeGap = 10.0, exchangeMinimumLines = 3, exchangeMaximumLines = 12
      public static let minimumDuration = 0.5, maximumDuration = 19.5
      public static let unclearCap = 100, exchangeCap = 20
  }
  public struct ClipCandidate: Equatable, Sendable { public var id: UUID; public var channel: UUID; public var sessionOffset: Double; public var duration: Double; public var confidence: Double? }
  public enum ClipChange: Equatable, Sendable {
      case hold(UUID)                              // keep the audio in memory for now
      case keep(UUID, ClipKind, exchange: Int?)    // write it (or update its record if written)
      case remove(UUID)                            // delete the file / drop the held audio
  }
  public struct ClipSelector: Sendable {
      public init(unclearCap: Int = ClipThresholds.unclearCap, exchangeCap: Int = ClipThresholds.exchangeCap,
                  random: @escaping @Sendable (Int) -> Int = { Int.random(in: 0..<$0) })
      /// `samplesEmpty` true when the line's audio couldn't be fetched.
      public mutating func offer(_ line: ClipCandidate, samplesEmpty: Bool = false) -> [ClipChange]
      /// Closes every open run (capture stopped).
      public mutating func finish() -> [ClipChange]
  }
  ```
- Rules the implementer must follow:
  - Skipped lines (`samplesEmpty`, duration < 0.5 or ≥ 19.5) produce no changes, don't count toward percentiles, and **break** the channel's open run.
  - Unclear: the line's confidence is nil or below the threshold computed from that channel's earlier confidences (before adding this one). Every accepted line's confidence is then added to the channel's history.
  - Unclear reservoir (Algorithm R): the n-th unclear line is kept if n ≤ cap; otherwise `let j = random(n)`, kept replacing slot `j` if `j < cap` (emit `.remove` for the replaced id unless it is held by an open run).
  - Runs: a line joins the channel's open run if `line.sessionOffset ≤ previous.sessionOffset + previous.duration + 10`, otherwise the open run closes first. A run reaching 12 lines closes at once. Lines in an open run are `.hold`. A closing run with ≥3 lines enters the exchange reservoir (same Algorithm R, counted in runs); if kept, emit `.keep(id, .exchange, exchange: k)` for each line (k counts kept exchanges from 1), and remove the lines from the unclear reservoir (freeing their slots, no `.remove`). A replaced exchange emits `.remove` for each of its lines. A run that isn't kept emits `.remove` for lines not held as unclear.
  - An unclear line in an open run gets `.keep(id, .unclear, exchange: nil)` at once (as well as being held by the run).

- [ ] **Step 1: Write the failing tests:**
  - `keepsLowConfidenceAfterWarmup`: 20 lines on one channel at confidence 0.9, 2 s each, 30 s apart (no runs): no keeps. Then 0.5 → `[.keep(id, .unclear, exchange: nil)]`. Then 0.95 → `[]`.
  - `warmupUsesFixedThreshold`: first line at 0.7 → kept; first line at 0.8 on another channel → not.
  - `nilConfidenceIsUnclear`: a nil-confidence line → kept unclear.
  - `channelsAreJudgedSeparately`: channel A has 20 lines at 0.6; channel B 20 at 0.95; a 0.7 line on A isn't unclear; a 0.9 line on B is.
  - `skipsEmptyAndOutOfRangeAudio`: `samplesEmpty: true`, duration 0.4, duration 19.5 → `[]` each, and a run open before them is closed (next nearby line starts a new run).
  - `threeCloseLinesMakeAnExchange`: 3 lines at 0.95 (after warmup on 20 lines 30 s apart), starting 0, 4, 8, 2 s each → `.hold` each; a 4th line at 100 → the 3 get `.keep(…, .exchange, exchange: 1)`; the 4th gets `.hold`.
  - `twoLinesAreNotAnExchange`: 2 close lines then a far one → the 2 get `.remove`.
  - `runClosesAtTwelveLines`: 12 close lines → the 12th offer also returns 12 `.keep(…exchange: 1)`.
  - `exchangeTakesOverUnclearLines`: an unclear line inside a kept run is kept once: its final state is `.exchange`, and the unclear count drops so a later unclear line fits under a cap of 1.
  - `reservoirSpreadsOverTheSession`: cap 10, `random` from a seeded generator, 1 000 unclear lines with offsets 0…999 × 30 s: exactly 10 kept at the end; at least 5 have offsets past line 500. Every `.remove` names a previously kept id.
  - `finishClosesOpenRuns`: 3 close lines then `finish()` → 3 `.keep(…exchange: 1)`.
- [ ] **Step 2:** Run `swift test --filter ClipSelectorTests`. Expected: FAIL.
- [ ] **Step 3:** Implement `ClipSelector`. Percentile by sorting a copy of the channel's confidences (sessions hold a few thousand lines per channel; fine off the audio thread).
- [ ] **Step 4:** Run. Expected: PASS.
- [ ] **Step 5:** Commit `Choose which lines to keep as clips`.

---

### Task 4: Clip keeper and tap

**Files:**
- Create: `Packages/WilcoCore/Sources/WilcoCore/Learning/ClipTap.swift`, `Packages/WilcoCore/Sources/WilcoTranscription/Learning/ClipKeeper.swift`
- Test: `Packages/WilcoCore/Tests/WilcoTranscriptionTests/ClipKeeperTests.swift`

**Interfaces:**
- Consumes: `ClipSelector`, `ClipChange`, `ClipsFolder`, `WAV`, `ClipManifest` (Tasks 2–3).
- Produces:
  ```swift
  // WilcoCore
  public struct ClipOffer: Sendable { public var candidate: ClipCandidate; public var engine: String; public var whisperModel: String?; public var samples: [Float] }
  public struct ClipTap: Sendable { public init(offer: @escaping @Sendable (ClipOffer) -> Void); public var offer: @Sendable (ClipOffer) -> Void }
  // WilcoTranscription
  public actor ClipKeeper {
      public init(folder: URL, selector: ClipSelector = ClipSelector(), queueLimit: Int = 32, saveInterval: Double? = 5)
      public nonisolated let tap: ClipTap
      public func finish() async        // drains, closes runs, writes manifest
      var manifest: ClipManifest { get } // tests
  }
  ```
- The tap yields into an `AsyncStream(bufferingPolicy: .bufferingOldest(queueLimit))`; a `.dropped` yield result increments a `Mutex<Int>` (Synchronization) that goes into `manifest.dropped`. The keeper writes WAVs for `.keep` (if not already written), deletes for `.remove`, keeps held samples in a dictionary until kept or removed, and saves the manifest every `saveInterval` seconds when changed, and in `finish()`. Any write error sets a flag and stops further writes. It never throws out of `tap.offer`.

- [ ] **Step 1: Write the failing tests:**
  - `keepsAndWritesUnclearClips`: keeper on a temp folder, `saveInterval: nil`; offer 1 line with confidence nil and 16 000 samples; `await finish()` → `clips.json` has 1 record (engine and offsets as offered), its WAV decodes to 16 000 samples.
  - `replacedClipsAreDeleted`: selector cap 1 with `random` returning 0; offer 2 unclear lines; after finish, 1 WAV on disk, and it's the second line's.
  - `exchangesAreWrittenWhenTheRunCloses`: 3 close lines at high confidence after warmup; finish → 3 records with `exchange == 1`, 3 WAVs.
  - `dropsWhenTheQueueIsFull`: `queueLimit: 2`; before the keeper drains (offer 10 synchronously from a non-isolated context), finish → `dropped ≥ 1`, and `records + dropped` accounts for every offer that the selector would keep.
  - `keeperSurvivesAnUnwritableFolder`: folder path under a file (not a directory); offering 5 lines and `finish()` neither throws nor hangs (`.timeLimit(.minutes(1))`).
- [ ] **Step 2:** Run `swift test --filter ClipKeeperTests`. Expected: FAIL.
- [ ] **Step 3:** Implement, following `DiagnosticsRecorder`'s shape (stream drained by an actor task; optional save loop).
- [ ] **Step 4:** Run. Expected: PASS.
- [ ] **Step 5:** Commit `Clip keeper`.

---

### Task 5: Offer every final line's audio

**Files:**
- Modify: `Packages/WilcoCore/Sources/WilcoTranscription/ChannelTranscriber.swift` (`AudioSource` gains `clips: ClipTap?`, init parameter `clips: ClipTap? = nil`)
- Modify: `.../WilcoTranscription/VoiceAnnotator.swift:189` (`deliverFinalLine`)
- Modify: `.../UtteranceChannelTranscriber.swift`, `.../WhisperChannelTranscriber.swift`, `.../AppleChannelTranscriber.swift`
- Test: `Packages/WilcoCore/Tests/WilcoTranscriptionTests/UtteranceTranscriberTests.swift`

**Interfaces:**
- Consumes: `ClipTap`, `ClipOffer`, `ClipCandidate`.
- Produces: `deliverFinalLine(_:voices:onEvent:lineStart:lineEnd:words:audio:clips:)` with new trailing parameter `clips: ChannelClips? = nil`, where
  ```swift
  struct ChannelClips: Sendable { var tap: ClipTap; var channel: UUID; var engine: String; var whisperModel: String? }
  ```
  `deliverFinalLine` calls `audio()` once and offers `ClipOffer(candidate: ClipCandidate(id: UUID(), channel:, sessionOffset: lineStart, duration: lineEnd - lineStart, confidence: line.confidence), …)` only when `clips` is non-nil and the line's text isn't empty.
- Engines: Parakeet passes `engine: SpeechEngine.parakeet.rawValue`; Whisper passes `.whisper` and its `whisperModel.rawValue`; Apple passes `configuration.engine.rawValue`. On Apple, create `history` when `annotator != nil || source.clips != nil`, and append real audio when `annotator?.isUsable == true || source.clips != nil` (otherwise `skip`, as today).

- [ ] **Step 1: Write the failing test** `offersEachFinalLineToTheClipTap` in `UtteranceTranscriberTests`, using the file's existing fake recognizer and `run`/`play` helpers: a source with a `ClipTap` that appends offers to a `Mutex<[ClipOffer]>`; play two calls with a pause; after stop, 2 offers; each `samples.count` equals the utterance length at 16 kHz (within 1 600 samples); `engine == "parakeet"`; `candidate.sessionOffset` equals the final event's `sessionOffset`.
- [ ] **Step 2:** Run `swift test --filter UtteranceTranscriberTests`. Expected: FAIL (no `clips` parameter).
- [ ] **Step 3:** Implement across the three engines.
- [ ] **Step 4:** Run `swift test`. Expected: all pass (existing callers compile through the defaults).
- [ ] **Step 5:** Commit `Offer final lines' audio to the clip keeper`.

---

### Task 6: Keep clips during capture (app)

**Files:**
- Modify: `Wilco/AppModel.swift` (`startCapture`, `stopCapture`)
- Modify: `Wilco/Capture/TranscriptionController.swift` (`var clips: ClipTap?`, pass to `AudioSource`)
- Create: `Wilco/Settings/LearningSettingsView.swift`; modify `Wilco/Settings/SettingsView.swift` (new `Tab("Learning", systemImage: "graduationcap")` after Languages)

**Interfaces:**
- Consumes: `ClipKeeper(folder:)`, `ClipsFolder.url(forTranscript:)`, `.totalSize(in:)`, `.deleteAll(in:)`.
- Produces: `AppModel.clipKeeper: ClipKeeper?` lifecycle mirroring `diagnostics`: made in `startCapture` only when `UserDefaults.standard.bool(forKey: "learning.keepClips")`; in `stopCapture`, taken out before the `Task` and `await keeper?.finish()` after `transcription.stopAll()`. Also `AppModel.lastCaptureStop: Date?`, set in `stopCapture` (used by Task 11).
- Settings tab, first section: `Toggle("Keep audio clips to learn from shows", isOn: $keepClips)` with `@AppStorage("learning.keepClips")`; caption "Short clips of unclear lines and exchanges, saved beside each session. They never leave this Mac. About 30–50 MB a show. Takes effect at the next capture."; "Using \(size)" via `ByteCountFormatter`; a **Delete All Clips** button disabled while capturing, with a SwiftUI `confirmationDialog` ("Delete all clips? Labels made from them go too."). Tasks 8 and 11 add the voters and progress rows to this view.

- [ ] **Step 1:** Implement the wiring and the tab.
- [ ] **Step 2:** Build: `xcodebuild build -project Wilco.xcodeproj -scheme Wilco -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY=""`. Expected: `BUILD SUCCEEDED`, no new warnings.
- [ ] **Step 3:** Commit `Keep clips during capture; Learning settings`.

---

### Task 7: Parakeet Ultra model store

**Files:**
- Modify: `Packages/WilcoCore/Sources/WilcoTranscription/ParakeetModelStore.swift`
- Modify: `Packages/WilcoCore/Sources/WilcoCore/Persistence/DataLocations.swift` (add `parakeetUltraModels` = `root/ParakeetUltraModels`, `sortformerModels` = `root/SortformerModels`)
- Test: `Packages/WilcoCore/Tests/WilcoTranscriptionTests/ParakeetTests.swift`

**Interfaces:**
- Produces: `ParakeetModelStore.init(directory: URL = DataLocations.parakeetModels, version: AsrModelVersion = .v3, vocabularyDirectory: URL? = nil)`. The TDT folder and `modelsExist`/`download`/`load` use `version`; the CTC folder uses `vocabularyDirectory ?? directory`. `remove()` removes only `directory`. Ultra store: `ParakeetModelStore(directory: DataLocations.parakeetUltraModels, version: .ultra, vocabularyDirectory: DataLocations.parakeetModels)`.

- [ ] **Step 1: Write the failing test** `ultraStoreSharesTheVocabularyModel`: with temp dirs, an Ultra store whose `vocabularyDirectory` holds a fake CTC folder layout reports `isVocabularyInstalled() == true` while `isInstalled() == false`; a default store over the same temp dir reports v3's folder name (`AsrModels.defaultCacheDirectory(for: .v3).lastPathComponent`) and the Ultra store reports `.ultra`'s. (Expose the TDT folder as `nonisolated var speechFolder: URL` internal for the test.)
- [ ] **Step 2:** Run `swift test --filter ParakeetTests`. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run `swift test`. Expected: PASS.
- [ ] **Step 5:** Commit `Parakeet model store for other versions`.

---

### Task 8: Voters

**Files:**
- Create: `Packages/WilcoCore/Sources/WilcoTranscription/Learning/ClipVoters.swift`
- Create: `Packages/WilcoCore/Sources/WilcoCore/Learning/ClipAgreement.swift`
- Test: `Packages/WilcoCore/Tests/WilcoCoreTests/ClipAgreementTests.swift`, gated `Packages/WilcoCore/Tests/WilcoTranscriptionTests/ClipVoterTests.swift`
- Modify: `Wilco/Settings/ModelInstaller.swift` (`Item.parakeetUltra`, `Item.sortformer`), `Wilco/Settings/LearningSettingsView.swift` (voters table)

**Interfaces:**
- Produces (WilcoCore):
  ```swift
  public enum ClipVoterID { public static let parakeetUltra = "parakeet-ultra", whisperLarge = "whisper-large-v3", appleLongForm = "apple-longform" }
  public enum ClipAgreement {
      /// Voters that sit out a clip because the channel's live engine is one of them.
      public static func sittingOut(engine: String, whisperModel: String?) -> Set<String>
      /// `voters` in preference order. Two voting: both must match. Three or more: any two.
      /// Fewer than two after sitting out: `.notEnoughVoters`. The text is the first
      /// matching voter's own text (casing kept); match = equal `TranscriptNormalizer.words`.
      public static func words(candidates: [String: String], voters: [String], sittingOut: Set<String>) -> (verdict: WordsVerdict, text: String?)
  }
  ```
- Produces (WilcoTranscription):
  ```swift
  public protocol ClipVoter: Sendable {
      var id: String { get }
      var version: String { get }           // goes into labels.voters; a change relabels
      func isInstalled() -> Bool
      func transcribe(_ samples: [Float], vocabulary: [String], localeIdentifier: String) async throws -> String
  }
  public struct ParakeetUltraVoter: ClipVoter   // ParakeetRecognizer(store: ultraStore, language: ParakeetLanguages.language(for:), vocabulary:)
  public struct WhisperLargeVoter: ClipVoter    // WhisperModelStore.transcribe(_, model: .large, language:, vocabulary:, translate: false), segments joined
  @available(macOS 26, *) public struct AppleLongFormVoter: ClipVoter  // see below
  public enum ClipVoters { public static func installed(ultra: ParakeetModelStore, whisper: WhisperModelStore) -> [any ClipVoter] }  // order: Ultra, Apple (macOS 26+, when its assets for en-US are installed), Whisper large
  ```
- `AppleLongFormVoter.transcribe`: one-shot `SpeechAnalyzer` with a `SpeechTranscriber` for the locale (via `SpeechAssets.module(engine: .longForm, localeIdentifier:, streaming: false, wordTimings: false)`), contextual strings set to the vocabulary as `AppleChannelTranscriber.begin` does; feed the clip converted with `SampleRateConverter(output: bestAvailableAudioFormat)`, then `finalizeAndFinishThroughEndOfInput()`; join final results. `version` = the OS version string.
- Plan-level call (not in the spec): before macOS 26 no Parakeet Unified voter in part 1. Those Macs label only with Ultra + Whisper large installed.
- Settings voters table rows: Parakeet Ultra (Download / Remove, size), Apple Long-form (status only; "Install in Languages" when missing), Whisper large-v3 "(optional, about 3 GB)" (uses existing `.whisper(.large)` item), Voice grouping (Sortformer; the item is installed by Task 9's `SortformerClipDiarizer.install`). A line under it: "Labelling needs at least two."

- [ ] **Step 1: Write the failing tests** (`ClipAgreementTests`):
  - `twoVotersMustBothMatch`: `["parakeet-ultra": "Standby Tea Time, cue five.", "apple-longform": "standby tea time cue 5"]`, voters `[ultra, apple]` → `.agreed`, text `"Standby Tea Time, cue five."`.
  - `twoVotersDisagree`: `"t time"` vs `"tea time"` → `.disputed`, nil.
  - `anyTwoOfThree`: Ultra `"go"`, Apple `"no"`, Whisper `"go"` → `.agreed`, `"go"` (Ultra's text).
  - `liveEngineSitsOut`: `sittingOut(engine: "whisper", whisperModel: "large") == ["whisper-large-v3"]`; `sittingOut(engine: "longForm", whisperModel: nil) == ["apple-longform"]`; `"parakeet"` → `[]`; with three voters and Whisper sitting out, Ultra `"a"`, Apple `"b"`, Whisper `"a"` → `.disputed`.
  - `tooFewVoters`: one candidate → `.notEnoughVoters`.
  - `emptyTextsDontAgree`: two empty strings → `.disputed`.
- [ ] **Step 2:** Run `swift test --filter ClipAgreementTests`. Expected: FAIL.
- [ ] **Step 3:** Implement `ClipAgreement`, the voters and the Settings rows.
- [ ] **Step 4:** Run `swift test`; gated `ClipVoterTests.votersTranscribeASayClip` (uses `SayClip.swift`; each installed voter's text contains "cue") with `WILCO_ASR_TESTS=1 swift test --filter ClipVoterTests`. Build the app. Expected: PASS, `BUILD SUCCEEDED`.
- [ ] **Step 5:** Commit `Voters and word agreement`.

---

### Task 9: Grouping voices

**Files:**
- Create: `Packages/WilcoCore/Sources/WilcoCore/Learning/VoiceAgreement.swift`
- Create: `Packages/WilcoCore/Sources/WilcoTranscription/Learning/ClipDiarizers.swift`
- Test: `Packages/WilcoCore/Tests/WilcoCoreTests/VoiceAgreementTests.swift`

**Interfaces:**
- Produces (WilcoCore):
  ```swift
  public struct SpeakerSpan: Equatable, Sendable { public var speaker: String; public var start: Double; public var end: Double }
  public enum VoiceAgreement {
      /// Where each clip sits when a channel's clips are joined with `gap` seconds of silence between.
      public static func layout(durations: [Double], gap: Double = 1) -> [ClosedRange<Double>]
      /// The speaker covering most of `range`, or nil if none overlaps.
      public static func speaker(of range: ClosedRange<Double>, in spans: [SpeakerSpan]) -> String?
      /// Per clip: the agreed speaker number, or nil. B's speakers are matched to A's by most
      /// shared clips; a clip agrees when its B speaker maps to its A speaker. Numbers follow
      /// A's speakers in order of first appearance, from 0.
      public static func agree(_ a: [String?], _ b: [String?]) -> [Int?]
  }
  ```
- Produces (WilcoTranscription):
  ```swift
  public protocol ClipDiarizer: Sendable { var id: String { get }; func isInstalled() -> Bool; func spans(of samples: [Float]) async throws -> [SpeakerSpan] }
  public struct PipelineClipDiarizer: ClipDiarizer   // OfflineDiarizerManager over the voice model folder WeSpeakerVoiceprints already downloads (DataLocations.voiceModels)
  public struct SortformerClipDiarizer: ClipDiarizer // OfflineSortformerDiarizer, models in DataLocations.sortformerModels
  extension SortformerClipDiarizer { public func install(progress: @escaping @Sendable (Double) -> Void) async throws; public func remove() throws }
  ```

- [ ] **Step 1: Write the failing tests:**
  - `layoutAddsGaps`: durations `[2, 3]` → `[0...2, 3...6]`.
  - `speakerCoveringMost`: spans `[A 0–1.5, B 1.5–2.2]`, range `0...2` → `"A"`; range `10...11` → nil.
  - `agreeMatchesRenamedSpeakers`: a `["s1","s1","s2","s2"]`, b `["x","x","y","y"]` → `[0,0,1,1]`.
  - `disagreementIsNil`: a `["s1","s1","s2"]`, b `["x","x","x"]` → `[0,0,nil]`.
  - `missingSpeakerIsNil`: a `["s1", nil]`, b `["x","x"]` → `[0, nil]`.
- [ ] **Step 2:** Run `swift test --filter VoiceAgreementTests`. Expected: FAIL.
- [ ] **Step 3:** Implement both files. Check FluidAudio's `OfflineSortformerDiarizer.processComplete` and `OfflineDiarizerManager.process(audio:)` result types in `.build/checkouts/FluidAudio` and map them to `SpeakerSpan`.
- [ ] **Step 4:** Run `swift test`. Expected: PASS.
- [ ] **Step 5:** Commit `Group voices with two offline diarizers`.

---

### Task 10: Labeller

**Files:**
- Create: `Packages/WilcoCore/Sources/WilcoTranscription/Learning/ClipLabeller.swift`
- Test: `Packages/WilcoCore/Tests/WilcoTranscriptionTests/ClipLabellerTests.swift`

**Interfaces:**
- Consumes: `ClipVoter`, `ClipDiarizer`, `ClipAgreement`, `VoiceAgreement`, `ClipsFolder`, `WAV`.
- Produces:
  ```swift
  public struct ClipLabeller: Sendable {
      public init(voters: [any ClipVoter], diarizers: [any ClipDiarizer])
      public var voterVersions: [String: String] { get }
      /// Labels one session's clips, saving labels.json after each clip. Clips already
      /// labelled with the same voters (and any with `checked`) are kept. Throws
      /// CancellationError between clips when cancelled; what's done is saved.
      public func label(transcript: URL, show: ShowDocument?, progress: @Sendable (Int, Int) -> Void) async throws
  }
  ```
- Per clip: vocabulary `show?.vocabulary(for: record.channel) ?? []`; locale from the show's channel, else `"en-US"`; each voter not sitting out transcribes; a voter that throws is left out of `candidates`. Voices after all words: per channel with ≥3 clips and 2 diarizers installed, join clips (`VoiceAgreement.layout`), run both, set `voice`/`speaker`. `finished = true` at the end. Records whose WAV is missing are skipped; WAVs not in the manifest are ignored.

- [ ] **Step 1: Write the failing tests** with fake voters (fixed texts per clip id, or a delay) and fake diarizers:
  - `labelsAgreedAndDisputedClips`: manifest of 2 clips; fake voters agree on clip 1, disagree on clip 2 → labels: clip 1 `.agreed` with text, clip 2 `.disputed`, `candidates` has both voters, `finished`.
  - `labellerStopsWhenCancelledAndResumes`: 5 clips, voters delay 50 ms each; cancel the task after the 2nd progress call → throws `CancellationError`; labels.json has 2 or 3 clips and `finished == false`; a second run calls the voters only for the remaining clips (count calls) and finishes.
  - `labellerIgnoresStrayFilesAndMissingAudio`: a stray `x.wav` not in the manifest and a record with no WAV → only the good clip is labelled; no throw.
  - `newVotersRelabelButKeepChecked`: existing finished labels with voters `{a}` and one clip with `checked: "x"`; run with voters `{a, b}` → that clip keeps `checked == "x"`, the other is relabelled; `voters` updated.
  - `voicesNeedThreeClipsAndTwoDiarizers`: 3 clips on one channel; fake diarizers whose spans put clip 1–2 as one speaker and 3 as another in both → speakers `[0,0,1]`, all `.agreed`; with one diarizer → all `voice == nil`.
- [ ] **Step 2:** Run `swift test --filter ClipLabellerTests`. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run. Expected: PASS. Then gated end to end: `labelsASayMadeSession` makes a `.clips` folder from 3 `say` clips and labels it with the installed voters; at least 2 are `.agreed` (`WILCO_ASR_TESTS=1`).
- [ ] **Step 5:** Commit `Label a session's clips`.

---

### Task 11: Run labelling after shows (app)

**Files:**
- Create: `Packages/WilcoCore/Sources/WilcoCore/Learning/LearningSchedule.swift`
- Test: `Packages/WilcoCore/Tests/WilcoCoreTests/LearningScheduleTests.swift`
- Create: `Wilco/Learning/LearningController.swift`; modify `Wilco/AppModel.swift`, `Wilco/Settings/LearningSettingsView.swift`

**Interfaces:**
- Produces (WilcoCore):
  ```swift
  public enum LearningSchedule {
      public static let delayAfterCapture: Double = 120
      public static func mayRun(now: Date, capturing: Bool, lastCaptureStop: Date?) -> Bool
  }
  ```
- Produces (app): `@MainActor @Observable final class LearningController { var status: String?; func check(); func captureStarted() }`. `check()` (on launch, on stop + 120 s via a timer, and every 60 s) starts one background `Task(priority: .background)` when `mayRun` is true and `ClipsFolder.needingLabels(in: DataLocations.transcripts, voters:)` is non-empty and at least two voters are installed. It labels sessions oldest first, with `show` = `SessionShow.load(forTranscript:)` ?? `SessionShow.bestMatch(…)` among saved shows. `captureStarted()` cancels the task (called first thing in `AppModel.startCapture`). `status` reads "Labelling clips: 40 of 120" while running, nil otherwise, shown in the Learning tab.

- [ ] **Step 1: Write the failing tests:**
  - `scheduleNeverRunsWhileCapturing`: `mayRun(now:, capturing: true, lastCaptureStop: nil) == false`.
  - `scheduleWaitsTwoMinutesAfterStopping`: stop at t; `now = t + 119` → false; `t + 120` → true.
  - `scheduleRunsAtLaunch`: `lastCaptureStop: nil`, not capturing → true.
- [ ] **Step 2:** Run `swift test --filter LearningScheduleTests`. Expected: FAIL.
- [ ] **Step 3:** Implement `LearningSchedule` and the controller.
- [ ] **Step 4:** Run `swift test`; build the app. Expected: PASS, `BUILD SUCCEEDED`.
- [ ] **Step 5:** Commit `Label clips in the background after shows`.

---

### Task 12: Accuracy per channel in the Review

**Files:**
- Create: `Packages/WilcoCore/Sources/WilcoCore/Report/Review/ClipAccuracy.swift`
- Modify: `.../Review/ShowReview.swift` (`make` gains `clips: SessionClips? = nil`; new `checkAccuracy`), `.../Review/SessionHistory.swift` (`SessionSummary.clipErrors: [UUID: WordErrors] = [:]`, `clipErrorRate: Double?`; filled in `summary(transcript:candidates:)`)
- Modify: `Wilco/Report/ReportModel.swift` (load and pass `SessionClips`), `Wilco/Report/ReviewView.swift` (trend column "Hard-line errors")
- Test: `Packages/WilcoCore/Tests/WilcoCoreTests/ClipAccuracyTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public struct SessionClips: Sendable { public var manifest: ClipManifest; public var labels: ClipLabels; public static func load(forTranscript: URL) -> SessionClips? }
  public enum ClipAccuracy {
      /// Final lines on the clip's channel with sessionOffset in [start − 0.5, start + duration], in order, joined by spaces.
      public static func liveText(for clip: ClipRecord, in segments: [TranscriptSegment]) -> String
      /// Per channel: clips with an answer, and the live text's word errors against the answers.
      public static func perChannel(segments: [TranscriptSegment], clips: SessionClips) -> [UUID: (clips: Int, errors: WordErrors)]
  }
  ReviewThresholds.accuracyMinimumClips = 10
  ```
- Finding: id `"accuracy"`, severity `.info`, title `"Accuracy on the hardest lines"`, detail one line per channel with ≥10 scored clips, highest rate first: `"\(name): \(pct)% of words wrong on \(n) clips"` plus `" (was \(prev)% last show)"` when the newest earlier session of the show has that channel with ≥10 clips. No fixes. Skipped when `clips` is nil.

- [ ] **Step 1: Write the failing tests:**
  - `liveTextJoinsLinesInsideTheClip`: segments on the channel at 9.6, 10.0 and 12.5, and one on another channel at 10.0; clip at 10, 3 s → text of the 9.6 and 10.0 lines joined; 12.5 included (≤ 13); the other channel isn't.
  - `perChannelScoresOnlyAnsweredClips`: 3 clips, labels agreed/disputed/checked → 2 counted; errors match `WordErrorRate.compare` of the answers against live texts.
  - `accuracyFindingNeedsTenClips`: 9 scored clips → no `"accuracy"` finding; 10 → one, detail contains `"% of words wrong on 10 clips"`.
  - `accuracyShowsLastShow`: history summary with `clipErrors` for the channel (10 clips, rate 0.2) → detail contains `"(was 20% last show)"`.
  - `olderSessionsWithoutClipsStillReview`: `make` with `clips: nil` gives the same findings as before (compare to a call without the argument).
- [ ] **Step 2:** Run `swift test --filter ClipAccuracyTests`. Expected: FAIL.
- [ ] **Step 3:** Implement, then the ReportModel/ReviewView changes.
- [ ] **Step 4:** Run `swift test` and the gated `reviewsEverySavedSession` style test if it exists locally; build the app. Expected: PASS, `BUILD SUCCEEDED`.
- [ ] **Step 5:** Commit `Review: accuracy on clips per channel, with trend`.

---

### Task 13: `wilco-bench --real-show`

**Files:**
- Create: `Packages/WilcoCore/Sources/WilcoBench/RealShowSet.swift`
- Modify: `.../WilcoBench/Scenario.swift` (`generateRealExchanges`), `.../WilcoBench/Scorer.swift` (optional clip filter), `.../WilcoBench/BenchReport.swift` (live row, voter marks), `.../wilco-bench/main.swift` (`--real-show`, `--transcripts DIR`)
- Test: `Packages/WilcoCore/Tests/WilcoBenchTests/RealShowTests.swift`

**Interfaces:**
- Consumes: `SessionClips`, `ClipAccuracy.liveText`, `WAV`, `ClipLabel.answer`, `WordErrorRate`.
- Produces:
  ```swift
  public struct RealExchange: Sendable { public var clips: [Int]; public var gaps: [Double] }   // gaps capped at 3 s
  public struct RealShowSet: Sendable {
      public var clips: [BenchClip]                   // answered clips; voice = unique per (session, channel, speaker), else a fresh number
      public var agreeingVoters: [Set<String>]        // per clip: voters whose text matched the answer
      public var exchanges: [RealExchange]            // exchanges whose clips all have answers and agreed voices
      public var live: WordErrors
      public var counts: (sessions: Int, agreed: Int, checked: Int, disputed: Int, dropped: Int)
      public static func load(transcripts: URL, sampleRate: Double) throws -> RealShowSet
      public var summary: String                      // numbers only
  }
  extension Scenario { public static func generateRealExchanges(channels: Int, duration: Double, seed: UInt64, exchanges: [RealExchange], clips: [ConversationClip]) -> Scenario }
  ```
- `--real-show` replaces the clip source (like `--corpus`; the two can't be combined). With `--conversation` it uses `generateRealExchanges` (exchanges placed whole, in order, original gaps, channels filled round-robin, each exchange its own `exchange` number). The report gains a `Live on the night` line (rate, clips) and marks voter engines (`parakeet-ultra`, `apple-longform*`, `whisper-large*`) with "(voter)" plus their rate on clips where they weren't among `agreeingVoters`.

- [ ] **Step 1: Write the failing tests** (temp folder with a `.jsonl`, manifest, labels and WAVs written by the test):
  - `loadsAnsweredClipsOnly`: 3 clips (agreed, checked, disputed) → 2 clips; counts `(1, 1, 1, 1, 0)`; clip texts are the answers; samples resampled to the requested rate (count ≈ duration × rate).
  - `liveErrorsComeFromTheTranscript`: the `.jsonl` line for the agreed clip differs by one word from the answer → `live.errors == 1`.
  - `summaryHoldsNoText`: answers containing `"Zebedee"` → `summary` doesn't contain it; contains `"2 clips"`.
  - `exchangesNeedAgreedVoices`: an exchange of 3 clips where one voice is disputed isn't in `exchanges`; one with all agreed is, gaps `[min(gap, 3)…]`.
  - `realExchangesKeepOrderAndGaps`: `generateRealExchanges` with one exchange of 3 clips (2 s each, gaps 1 and 5) on 1 channel → starts `t, t+3, t+8` (second gap capped at 3), same `exchange` number.
- [ ] **Step 2:** Run `swift test --filter RealShowTests`. Expected: FAIL.
- [ ] **Step 3:** Implement, then the CLI options and report lines.
- [ ] **Step 4:** Run `swift test`; then `swift run -c release wilco-bench --help` lists `--real-show` and `--transcripts`. Expected: PASS.
- [ ] **Step 5:** Commit `Bench: real-show set from the app's labelled clips`.

---

### Task 14: Docs

**Files:**
- Modify: `docs/SPEC.md` (the `.clips` folder: `clips.json`, `labels.json`, WAV format; the Learning settings tab and `learning.keepClips`; labelling timing; the Review's accuracy finding)
- Modify: `docs/BENCHMARK.md` (`--real-show`, `--transcripts`, the Live row, voter marks, numbers-only output)

- [ ] **Step 1:** Write both sections in the docs' existing plain style. No clip text, no real channel names.
- [ ] **Step 2:** Commit `Docs: clips, labels and the real-show set`.

---

### Task 15: Whole-branch check and merge

- [ ] **Step 1:** `cd Packages/WilcoCore && swift test` → all pass. `WILCO_ASR_TESTS=1 swift test --filter "ClipVoterTests|ClipLabellerTests"` → pass (with Ultra, Apple Long-form and optionally Whisper large installed).
- [ ] **Step 2:** App build command → `BUILD SUCCEEDED`, no warnings.
- [ ] **Step 3:** Hand check in the app (record in PROGRESS as tested, not verified): switch on, capture 3 minutes of talk, stop; a `.clips` folder appears, isn't a session, the Review opens; after 2 minutes the Learning tab shows labelling progress; starting capture during it stops it.
- [ ] **Step 4:** Merge `learning-clips` into `main` and push.
