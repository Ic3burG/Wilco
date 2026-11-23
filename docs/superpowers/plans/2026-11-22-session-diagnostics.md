# Session diagnostics Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every session writes a per-channel, per-minute diagnostics file (levels, dropouts, speech/music/singing), and the post-show Review uses it to explain quiet channels and flag music, hot, low and lost-audio channels.

**Architecture:** A `ChannelMeter` (WilcoCore) is fed by each engine's read loop through `AudioSource`, off the audio thread. At each minute it hands a `ChannelMinute` row and an optional 3 s clip to a `DiagnosticsRecorder` (WilcoTranscription), which gets the clip classified by a shared `SoundClassifierQueue` (SoundAnalysis), merges partial rows and appends them through a `DiagnosticsWriter`. The report loads `SessionDiagnostics` and passes it to `ShowReview.make`.

**Tech Stack:** Swift 6 (strict concurrency), Swift Testing, Accelerate (vDSP), SoundAnalysis (`SNClassifySoundRequest`, `.version1`), SwiftUI app target.

**Spec:** `docs/superpowers/specs/2026-11-22-session-diagnostics-design.md` (read it first; field meanings and thresholds come from it).

## Global Constraints

- Work in a separate worktree (`../Wilco-diagnostics`, branch `session-diagnostics` off `main`); other sessions commit in the main checkout.
- File name: `Session yyyy-MM-dd HHmm-ss.diagnostics` beside the transcript. **Never** a `.jsonl` extension.
- Every row carries `"v":1`; decoding is lenient (unknown fields ignored, missing optionals nil, unparseable lines skipped).
- No audio written to disk; clips live in memory only.
- Nothing runs in the capture callback. The meter runs in transcriber read loops.
- The transcript `.jsonl` format, `.wilco` shows and preferences are unchanged. Sessions without the file get today's Review.
- Deployment target macOS 15; CI uses Xcode 26.6, so no macOS 27 SDK APIs.
- No reference-app names anywhere. New logic gets tests (Swift Testing). Fix warnings; don't silence them.
- Thresholds (all in `ReviewThresholds`): sound floor −46 dBFS (0.005 linear); clipped ≥ 0.999; a sound minute has `sound ≥ 1` s; no input = peak < −60 dBFS all session; low level = median `rms` < −40 dBFS; quiet "has sound" = sound minutes ≥ 10% of minutes; music = ≥ 30 classified sound minutes and music-or-singing beats speech in ≥ 60%; hot = clipping in ≥ 5% of sound minutes; level low needs ≥ 30 sound minutes; lost = dropped ≥ 5 s total or any counted minute with `audio < 50`; highlight fix needs ≥ 10 hits (existing `busyHighlightHits`).
- Classifier: one 3 s clip per channel per minute; at most one classification at a time; drop when 64 are waiting; a row waits for its classification up to 30 s past the end of its minute.

## Review Focus

1. **An engine stuck for minutes** (a model call that hangs): rows for those minutes never come. `SessionDiagnostics` must count a gap between two rows of a channel as lost audio unless the row before the gap is `partial` (the channel was stopped or muted). Test in Task 6.
2. **Device sample rate changes mid-minute** (48 → 44.1 kHz): `audio` seconds must use each block's own rate, and a clip in progress restarts at the new rate. Test in Task 2.
3. **Crash mid-write**: the last line of the file is cut off. Loading skips it and keeps every earlier row. Test in Task 1.
4. **Digital silence** (an unplugged input reading zeros): `peak`, `rms` and `floor` are null, no clip is taken, and the Review says "no input", not "low level". Tests in Tasks 2 and 7.
5. **Classifier never answers or is swamped**: rows are still written, without `classified`, once 30 s past their minute; stopping capture writes everything without waiting forever. Test in Task 5.

---

### Task 1: Diagnostics row, file name, writer and reader

**Files:**
- Create: `Packages/WilcoCore/Sources/WilcoCore/Persistence/DiagnosticsFile.swift`
- Test: `Packages/WilcoCore/Tests/WilcoCoreTests/DiagnosticsFileTests.swift`

**Interfaces:**
- Produces:
  - `public struct SoundShares: Codable, Equatable, Sendable { public var speech, music, singing: Double }`
  - `public struct ChannelMinute: Codable, Equatable, Sendable` with `v: Int = 1`, `channel: UUID`, `minute: Int`, `audio: Double`, `sound: Double`, `rms: Double?`, `peak: Double?`, `floor: Double?`, `clipped: Int`, `dropped: Int` (frames), `droppedSeconds: Double` (encoded as `"droppedSeconds"`), `utterances: Int?`, `speech: Double?`, `cuts: Int?`, `recognize: Double?`, `partial: Bool?` (encoded only when true), `classified: SoundShares?`. Nil fields are omitted when encoding.
  - `public mutating func merge(_ other: ChannelMinute)`: adds `audio`, `sound`, `clipped`, `dropped`, `droppedSeconds`, `utterances`, `speech`, `cuts`, `recognize` (nil + x = x); `peak` = max; `rms` = the one with more `sound` (whole-minute RMS can't be rebuilt from two RMS values without sums; good enough); `floor` = min; `partial` = true; `classified` = first non-nil.
  - `public enum DiagnosticsFile { static let fileExtension = "diagnostics"; static func url(forTranscript: URL) -> URL; static func line(for: ChannelMinute) -> Data; static func rows(in: Data) -> [ChannelMinute] }`
  - `public final class DiagnosticsWriter { init(url: URL); func append(_ row: ChannelMinute) throws }` creates the file and folder on the first row, like `TranscriptWriter`.

- [ ] **Step 1: Write the failing tests**

```swift
@Suite("Diagnostics file")
struct DiagnosticsFileTests {
    @Test func urlSitsBesideTranscriptAndIsNotJSONL() {
        let transcript = URL(fileURLWithPath: "/t/Session 2026-11-21 1720-05.jsonl")
        let url = DiagnosticsFile.url(forTranscript: transcript)
        #expect(url.lastPathComponent == "Session 2026-11-21 1720-05.diagnostics")
        #expect(url.pathExtension != "jsonl")
    }
    @Test func roundTripsAndOmitsNils()            // encode a row with nil rms/utterances/partial; decoded == original; line text has no "rms", "utterances" or "partial" key and contains "\"v\":1"
    @Test func unknownFieldsAndMissingOptionalsDecode() // {"v":2,"channel":…,"minute":3,"audio":60,"sound":0,"clipped":0,"dropped":0,"droppedSeconds":0,"future":true} decodes, rms == nil
    @Test func truncatedLastLineIsSkipped()         // two good lines + "{\"v\":1,\"chan" → 2 rows
    @Test func mergeAddsCountsAndKeepsMaxPeak()     // a(audio 20, peak -10, cuts 1) merge b(audio 35, peak -3, cuts nil) → audio 55, peak -3, cuts 1, partial true
    @Test func writerCreatesFileOnFirstRowOnly()    // temp dir: init alone leaves no file; after two appends, rows(in:) returns both in order
}
```

- [ ] **Step 2: Run and see them fail**

Run: `cd Packages/WilcoCore && swift test --filter DiagnosticsFileTests`
Expected: compile failure, `ChannelMinute` not found.

- [ ] **Step 3: Implement `DiagnosticsFile.swift`** with the interfaces above. Encode with `WilcoJSON.encoder()` minus pretty-printing, one object plus `\n` per row (check what `TranscriptFile.line(for:)` does and match it). `rows(in:)` splits on newlines and `try?`-decodes each line.

- [ ] **Step 4: Run the tests and see them pass**

Run: `swift test --filter DiagnosticsFileTests` → all pass.

- [ ] **Step 5: Commit** `Diagnostics: row format, file name, writer`

---

### Task 2: Channel meter and cut flag

**Files:**
- Create: `Packages/WilcoCore/Sources/WilcoCore/Audio/ChannelMeter.swift`
- Modify: `Packages/WilcoCore/Sources/WilcoCore/Transcription/UtteranceSegmenter.swift` (add `wasCut` to `Utterance`, set in `cutAtLastGap`)
- Test: `Packages/WilcoCore/Tests/WilcoCoreTests/ChannelMeterTests.swift`, `TranscriptionLogicTests.swift` (segmenter)

**Interfaces:**
- Consumes: `ChannelMinute` (Task 1).
- Produces:
  - `UtteranceSegmenter.Utterance.wasCut: Bool` (default `false`, so existing `Utterance(samples:startOffset:)` calls compile).
  - `public struct MeterClip: Sendable { public var samples: [Float]; public var sampleRate: Double }`
  - `public struct MeterReport: Sendable { public var row: ChannelMinute; public var clip: MeterClip? }`
  - `public struct DiagnosticsTap: Sendable { public var sessionStart: Date; public var sink: @Sendable (MeterReport) -> Void; public init(sessionStart:sink:) }`
  - `public struct ChannelMeter: Sendable` with:
    - `init(channelID: UUID, tap: DiagnosticsTap, countsUtterances: Bool, clipSeconds: Double = 3)`
    - `mutating func add(_ samples: [Float], sampleRate: Double, droppedFrames: Int, at now: Date)`; call it on every read, even an empty one, so minutes close while a channel gets no audio
    - `mutating func recognized(modelSeconds: Double, audioSeconds: Double, cut: Bool)`
    - `mutating func finish(at now: Date)` emits the current minute with `partial: true`
  - Minute index = `floor(now.timeIntervalSince(sessionStart) / 60)`. When `add` sees a later minute, it emits the current one, then starts the new one. The first minute a meter emits is `partial: true`.
  - `dropped` = `droppedFrames` now minus at the start of the minute; `droppedSeconds` = that divided by the rate.
  - Per minute it keeps sums and a fixed histogram of 20 ms frame levels in 1 dB bins from −120 to 0 (for `floor`, the 10th percentile), so it stores no frames. Frames are 20 ms at the block's own rate; leftover samples carry into the next block.
  - The clip is the first 3 s run of audio starting at a frame above −46 dBFS. A rate change restarts a clip in progress. A minute that ends before 3 s are gathered emits no clip.
  - With `countsUtterances`, `utterances`, `speech`, `cuts` and `recognize` are 0 when nothing was recognised; without it, nil.

- [ ] **Step 1: Write the failing tests** (inject `now`, collect reports through the sink into a `Mutex<[MeterReport]>`)

```swift
@Test func toneMinuteHasLevelsAndAClip()      // 61 s of a 0.1-amplitude 1 kHz sine at 48 kHz fed in 100 ms blocks with now advancing → first report: minute 0, partial true, audio ≈ 60 (±0.2), sound ≈ 60, rms ≈ -23 (±0.5), peak ≈ -20 (±0.1), clipped 0, clip?.samples.count == 144_000
@Test func silenceHasNoLevelsAndNoClip()      // zeros for 61 s → rms nil, peak nil, floor nil, sound 0, clip nil
@Test func clippedSamplesCounted()            // one block containing 10 samples of 1.0 → clipped 10
@Test func droppedFramesAreTheMinutesDifference() // droppedFrames 0 at the start, 4_800 at 30 s, 9_600 in minute 1 → minute 0 dropped 4_800, droppedSeconds 0.1; minute 1 dropped 4_800
@Test func emptyReadsStillCloseTheMinute()    // add([] …) at 10 s and 70 s → one report for minute 0 with audio 0
@Test func rateChangeCountsSecondsPerBlock()  // 30 s at 48 kHz then 30 s at 44.1 kHz → audio ≈ 60
@Test func rateChangeRestartsTheClip()        // sound starts at 59 s at 48 kHz, the rate changes at 59.5 s → minute 0 has no clip; the next minute's clip is at 44.1 kHz
@Test func utteranceCountsOnlyWhenCounting()  // countsUtterances true: recognized(1.2, 20, cut: true) → utterances 1, speech 20, cuts 1, recognize 1.2; false → all nil
@Test func finishEmitsPartialMinute()         // add 10 s, finish → partial true, audio ≈ 10
```

Segmenter test in `TranscriptionLogicTests.swift`: `@Test func cutAtLimitIsMarked()` (25 s of continuous speech-like noise with `maximumLength = 20` → first utterance `wasCut == true`; an utterance ended by silence → `false`).

- [ ] **Step 2: Run them and see them fail**

Run: `swift test --filter "ChannelMeterTests|cutAtLimitIsMarked"` → compile failure.

- [ ] **Step 3: Implement `ChannelMeter` and `wasCut`.** Use vDSP for sum of squares and the max magnitude (`LevelMath.peak`). Keep dBFS conversion in one helper (`20·log10`, nil for 0).

- [ ] **Step 4: Run the tests and see them pass.** Then run the whole package with `swift test`; the segmenter change must not break existing tests.

- [ ] **Step 5: Commit** `Diagnostics: channel meter; mark utterances cut at the limit`

---

### Task 3: Engines feed the meter

**Files:**
- Modify: `Packages/WilcoCore/Sources/WilcoTranscription/ChannelTranscriber.swift` (`AudioSource`)
- Modify: `UtteranceChannelTranscriber.swift`, `WhisperChannelTranscriber.swift`, `AppleChannelTranscriber.swift`
- Test: `Packages/WilcoCore/Tests/WilcoTranscriptionTests/UtteranceTranscriberTests.swift`

**Interfaces:**
- Consumes: `DiagnosticsTap`, `ChannelMeter`, `Utterance.wasCut` (Task 2).
- Produces:
  - `AudioSource.diagnostics: DiagnosticsTap?`, a new init parameter defaulting to nil (existing call sites unchanged).
  - `extension AudioSource { func read(metering meter: inout ChannelMeter?) -> [Float] }` reads everything available and calls `meter?.add(samples, sampleRate: sampleRate(), droppedFrames: ring.droppedFrames, at: Date())`.
  - Each engine holds `private var meter: ChannelMeter?`, made in `start()` after the "discard audio that queued" read (so the drained audio isn't counted). Utterance and Whisper engines pass `countsUtterances: true`; Apple passes false. Every read loop uses `source.read(metering: &meter)`. Utterance and Whisper engines call `meter?.recognized(modelSeconds:audioSeconds:cut:)` around each final `recognize`/`transcribe` call (time it with `ContinuousClock`). `stop()` calls `meter?.finish(at: Date())` after the pump ends.

- [ ] **Step 1: Write the failing test** `@Test func meteredChannelReportsUtterances()`. Use the file's existing fake recognizer, a tap whose `sessionStart` is 59 s in the past (so the first minute closes within the test), and feed speech-like audio with a pause. Stop the transcriber. Expect at least one report for the channel with `utterances ≥ 1`, `recognize ≥ 0`, `cuts == 0`, and the last report `partial == true`.

- [ ] **Step 2: Run it and see it fail**

Run: `swift test --filter meteredChannelReportsUtterances` → compile failure (no `diagnostics:`).

- [ ] **Step 3: Implement** as in Interfaces.

- [ ] **Step 4: Run the transcription tests and see them pass**

Run: `swift test --filter WilcoTranscriptionTests` → pass (ASR-gated ones skip).

- [ ] **Step 5: Commit** `Diagnostics: engines feed a meter from their read loop`

---

### Task 4: Sound classifier queue

**Files:**
- Create: `Packages/WilcoCore/Sources/WilcoTranscription/SoundClassifierQueue.swift`
- Modify: `Packages/WilcoCore/Package.swift` (link `SoundAnalysis` and `AVFoundation` for WilcoTranscription if not already linked)
- Test: `Packages/WilcoCore/Tests/WilcoTranscriptionTests/SoundClassifierQueueTests.swift`

**Interfaces:**
- Consumes: `MeterClip`, `SoundShares`.
- Produces:
  - `public actor SoundClassifierQueue { public init(maxWaiting: Int = 64, classify: @escaping @Sendable (MeterClip) async -> SoundShares? = SoundClassifierQueue.builtIn); public func classify(_ clip: MeterClip) async -> SoundShares?; public var droppedClips: Int { get } }`
  - `classify` returns nil at once (and counts a drop) when `maxWaiting` clips are already waiting. Otherwise it waits its turn, so only one classification runs at a time (serialise explicitly; actor reentrancy alone won't), and runs at `.utility` priority.
  - `public static func builtIn(_ clip: MeterClip) async -> SoundShares?`: an `SNAudioStreamAnalyzer` on a mono float `AVAudioFormat` at the clip's rate with `SNClassifySoundRequest(classifierIdentifier: .version1)`. Keep the maximum confidence over all windows for the labels `speech`, `music` and `singing`. Returns nil on any error.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func classifiesOneAtATime()     // injected classify tracks how many run at once with a Mutex; 10 concurrent calls → max concurrent 1, all non-nil
@Test func dropsWhenTooManyWait()     // maxWaiting 2, classify blocks until released; 5 concurrent calls → 1 running + 2 waiting are accepted, the other 2 return nil at once; droppedClips == 2
@Test(.enabled(if: ProcessInfo.processInfo.environment["WILCO_ASR_TESTS"] != nil))
func builtInHearsSpeech()             // a `say` clip (via WilcoBench's ClipLibrary, as other gated tests do) → speech > music
```

- [ ] **Step 2: Run them and see them fail** (`swift test --filter SoundClassifierQueueTests` → compile failure).

- [ ] **Step 3: Implement.**

- [ ] **Step 4: Run them and see them pass.** Also run with `WILCO_ASR_TESTS=1 swift test --filter builtInHearsSpeech`.

- [ ] **Step 5: Commit** `Diagnostics: shared sound classifier queue`

---

### Task 5: Diagnostics recorder

**Files:**
- Create: `Packages/WilcoCore/Sources/WilcoTranscription/DiagnosticsRecorder.swift`
- Test: `Packages/WilcoCore/Tests/WilcoTranscriptionTests/DiagnosticsRecorderTests.swift`

**Interfaces:**
- Consumes: `MeterReport`, `ChannelMinute.merge`, `DiagnosticsWriter`, `DiagnosticsTap` (Tasks 1–2), `SoundClassifierQueue` (Task 4).
- Produces:
  - `public actor DiagnosticsRecorder { public init(writer: DiagnosticsWriter, sessionStart: Date, classifier: SoundClassifierQueue?, hold: Double = 30, now: @escaping @Sendable () -> Date = Date.init); public nonisolated var tap: DiagnosticsTap { get }; public func writeDue() ; public func finish() async }`
  - `tap.sink` yields into an `AsyncStream` that the recorder drains in order. Each report's clip goes to the classifier in its own task; the shares land on that (channel, minute) row.
  - Rows are keyed by (channel, minute); a second report for the same key merges into the first.
  - `writeDue()` writes and forgets rows whose `sessionStart + (minute + 1) · 60 + hold` has passed, sorted by minute, then channel UUID string. A loop calls it every 5 s while the recorder runs.
  - `finish()` drains the stream, waits for outstanding classifications for at most `hold` seconds, then writes every row left.

- [ ] **Step 1: Write the failing tests** (writer to a temp dir; injected `now`; classifier with injected `classify`)

```swift
@Test func mergesARestartedChannelsMinute()   // two partial reports for (ch, 12) → after writeDue at minute 13.6 the file has one row, audio summed, partial true
@Test func waitsForClassification()            // classify returns shares after a short delay; writeDue past the hold → row has classified
@Test func writesWithoutClassificationAfterHold() // classify never returns; writeDue at minute end + 31 s → row written, classified nil
@Test func finishWritesEverythingAndReturns()  // pending rows + a never-returning classifier; finish() returns within ~hold (use hold 0.2 in the test) and the file has all rows
@Test func rowsNotYetDueStayHeld()             // writeDue at minute end + 10 s → file absent
```

- [ ] **Step 2: Run them and see them fail.**

- [ ] **Step 3: Implement.**

- [ ] **Step 4: Run them and see them pass.**

- [ ] **Step 5: Commit** `Diagnostics: recorder merges minutes and writes the file`

---

### Task 6: Reading a session's diagnostics

**Files:**
- Create: `Packages/WilcoCore/Sources/WilcoCore/Report/Review/SessionDiagnostics.swift`
- Test: `Packages/WilcoCore/Tests/WilcoCoreTests/SessionDiagnosticsTests.swift`

**Interfaces:**
- Consumes: `DiagnosticsFile`, `ChannelMinute` (Task 1).
- Produces:
  - `public struct ChannelDiagnostics: Sendable { minutes: Int; soundMinutes: Int; soundSeconds: Double; peak: Double?; medianRMS: Double?; clippedSoundMinuteShare: Double; droppedSeconds: Double; lostMinutes: [Int]; classifiedSoundMinutes: Int; speechMinutes: Int; musicMinutes: Int; cuts: Int? }`
  - `public struct SessionDiagnostics: Sendable { public var channels: [UUID: ChannelDiagnostics]; public static func make(_ rows: [ChannelMinute]) -> SessionDiagnostics; public static func load(forTranscript: URL) -> SessionDiagnostics? }`. `load` returns nil when the file is missing or has no rows.
  - Rules:
    - A sound minute has `sound ≥ 1`. `medianRMS` is over sound minutes. `peak` is the max over all rows (nil if all nil).
    - A classified sound minute is a sound minute with `classified`. It is a speech minute if `speech ≥ 0.5`, and a music minute if `max(music, singing) > speech`.
    - `lostMinutes`: non-partial rows with `audio < 50` (a channel's first and last rows are partial by construction), plus every missing minute between two rows unless the row before the gap is partial.
    - `cuts` is the sum, or nil if every row's `cuts` is nil.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func summarisesLevelsAndSound()          // 3 rows, 2 with sound → soundMinutes 2, medianRMS of those two, peak max
@Test func shortMinuteCountsAsLostUnlessPartial() // rows 0(partial),1(audio 30),2(audio 60),3(partial, audio 10) → lostMinutes [1]
@Test func gapAfterFullRowIsLost()             // rows 0p,1,4,5p → lostMinutes [2,3]
@Test func gapAfterStopIsNotLost()             // rows 0p,1,2p,7p,8p (muted 3–6) → lostMinutes []
@Test func musicAndSpeechMinutes()             // classified sound minutes: speech .9/music .1, speech .2/singing .7, speech .1/music .3 → speech 1, music 2
@Test func cutsNilForAppleEngine()             // all cuts nil → nil; one 2 → 2
@Test func loadReturnsNilWithoutFile()
```

- [ ] **Step 2: Run them and see them fail.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run them and see them pass.**
- [ ] **Step 5: Commit** `Diagnostics: per-channel summary for the review`

---

### Task 7: Review checks that use diagnostics

**Files:**
- Modify: `Packages/WilcoCore/Sources/WilcoCore/Report/Review/ShowReview.swift`
- Test: `Packages/WilcoCore/Tests/WilcoCoreTests/ReviewTests.swift`

**Interfaces:**
- Consumes: `SessionDiagnostics`, `ChannelDiagnostics` (Task 6).
- Produces:
  - `ShowReview.make(segments:show:history:showIsKnown:diagnostics: SessionDiagnostics? = nil)`
  - New `ReviewThresholds` constants with the Global Constraints values: `noInputPeak = -60`, `lowLevelRMS = -40`, `soundMinuteSeconds = 1.0`, `quietSoundShare = 0.1`, `musicMinimumMinutes = 30`, `musicShare = 0.6`, `hotClipShare = 0.05`, `lowLevelMinimumMinutes = 30`, `lostDroppedSeconds = 5.0`, `lostMinuteAudio = 50.0`.
  - Finding ids: `music:<channel>` (info), `hot:<channel>` (warning), `low:<channel>` (warning), `lost:<channel>` (warning).
  - Behaviour:
    - The diagnostics checks (music, hot, low, lost) run whenever diagnostics exist, even under 50 lines: a music channel can have few lines. Quiet stays inside the 50-line gate.
    - Music fixes come only when `show.channel(id:)` exists. They are the same highlight fixes as busy (pull busy's highlight-hit counting into a shared helper) plus Mute.
    - Quiet: each listed channel gets a reason in its detail, in this order: no input (peak nil or < −60), low level (sound minutes ≥ 10% of minutes and medianRMS < −40), not speech (sound minutes ≥ 10% and speech minutes < half of classified sound minutes), otherwise quiet (no reason text). Without diagnostics the text stays as today.
    - Low level isn't raised for a channel the quiet finding lists. Unclear's detail gains "Its level was low (median −NN dBFS), which may be why." when the same channel's medianRMS is below −40.
    - Cut uses the sum of diagnostics `cuts` when any channel has non-nil cuts, otherwise the current text estimate.
    - Lost names up to five minutes as clock times from `stats.start`. Its detail mentions falling behind when a `behind` finding exists.

- [ ] **Step 1: Write the failing tests.** Build `SessionDiagnostics.make` from hand-made rows.

```swift
@Test func noDiagnosticsKeepsTodaysFindings()   // existing fixture session, diagnostics nil vs today → identical finding ids
@Test func musicChannelOffersMuteAndHighlightFix() // 40 classified sound minutes, 30 music → finding "music:<id>" with .muteChannel(id) and .keepHighlight when ≥10 hits
@Test func musicWithoutChannelInShowHasNoFixes()
@Test func hotChannelFlagged()                  // 40 sound minutes, 3 clipped (7.5%) → "hot:<id>"; 1 clipped (2.5%) → none
@Test func lowLevelFlaggedAndUnclearMentionsIt() // 40 sound minutes at -45 dBFS + low-confidence lines → "low:<id>", unclear detail contains "level was low"
@Test func quietReasons()                       // four quiet channels: silent (peak nil) → "no input"; -50 rms with sound → "level"; music → "not speech"; normal level, no sound → no reason
@Test func lostAudioFromDropsAndGaps()          // droppedSeconds 6 → "lost:<id>"; a lost minute → named in detail
@Test func cutUsesExactCount()                  // diagnostics cuts 12, text estimate 0 → "cut" finding says 12
@Test func diagnosticsChecksRunUnderFiftyLines() // 10 lines, music diagnostics → music finding present
```

Add to the gated `"Review on real sessions"` suite: `@Test func reviewsSessionsWithDiagnostics()`. For each transcript whose `DiagnosticsFile.url` exists, build the review with diagnostics and print the diagnostics finding ids per session. It checks no thresholds; it's the tuning aid. It passes with zero such files.

- [ ] **Step 2: Run them and see them fail.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run all package tests and see them pass** (`swift test`). The existing review tests must be unchanged.
- [ ] **Step 5: Commit** `Review: findings from session diagnostics`

---

### Task 8: Wire it into the app

**Files:**
- Modify: `Wilco/AppModel.swift` (`startCapture`, `stopCapture`)
- Modify: `Wilco/Capture/TranscriptionController.swift` (`start`)
- Modify: `Wilco/Report/ReportModel.swift` (`load`, `reviewInput`, `rebuildReview`)

**Interfaces:**
- Consumes: `DiagnosticsRecorder`, `SoundClassifierQueue`, `DiagnosticsWriter`, `DiagnosticsFile.url`, `SessionDiagnostics.load`, `ShowReview.make(…diagnostics:)`.
- Produces:
  - `AppModel` keeps one `SoundClassifierQueue` for the app's lifetime, and one `DiagnosticsRecorder` per session, made in `startCapture` beside the `TranscriptWriter` with `DiagnosticsFile.url(forTranscript:)` of the same transcript URL.
  - `TranscriptionController.diagnostics: DiagnosticsTap?`, set before `reconcile` in `startCapture`. `start(...)` passes it into `AudioSource(…, diagnostics:)`, so restarts and show edits mid-capture keep metering.
  - `stopCapture`: after `await transcription.stopAll()`, `await recorder.finish()`, then clear it and the controller's tap.
  - `ReportModel.load` loads `SessionDiagnostics.load(forTranscript: url)` in the same detached task and carries it in `reviewInput` to `ShowReview.make`.

- [ ] **Step 1: Implement** as above.
- [ ] **Step 2: Build the app**

Run (from the repo root): `xcodebuild build -project Wilco.xcodeproj -scheme Wilco -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY=""`
Expected: `** BUILD SUCCEEDED **` with no new warnings.

- [ ] **Step 3: Smoke run** (follow the drive-the-app memory; quit the reference app first). Capture for about 2 minutes with a few channels, then stop. Check that `Session … .diagnostics` exists beside the new `.jsonl`, that its rows decode (`swift test` reader, or `head`), and that it isn't listed as a session in the report window.
- [ ] **Step 4: Commit** `App: write session diagnostics; review reads them`

---

### Task 9: Benchmark the cost and document the format

**Files:**
- Modify: `Packages/WilcoCore/Sources/WilcoBench/BenchRunner.swift`, `Packages/WilcoCore/Sources/wilco-bench/main.swift`, the bench report (`BenchReport.swift`)
- Modify: `docs/SPEC.md` (a "Session diagnostics file" section: name, fields table from the spec, lenient decoding, `v`)
- Modify: `docs/BENCHMARK.md` (the `--diagnostics` option)
- Modify: `docs/superpowers/specs/2026-11-22-show-review-design.md` (stage 2 section points to the diagnostics design)
- Test: `Packages/WilcoCore/Tests/WilcoBenchTests/BenchLogicTests.swift`

**Interfaces:**
- Consumes: `DiagnosticsRecorder`, `SoundClassifierQueue`, `AudioSource(diagnostics:)`.
- Produces:
  - `BenchRunner.diagnostics: Bool = false`. When it's true, a run makes a recorder writing to a temp file and passes its tap into every channel's `AudioSource`. It finishes the recorder after the run, and `RunResult` gains `droppedClips: Int?` (nil when off).
  - `wilco-bench --diagnostics` sets it. The Markdown table gains a "clips dropped" column when on.

- [ ] **Step 1: Write the failing test** `@Test func diagnosticsRunReportsDroppedClips()`: a short run (a few seconds, 2 channels, the fake engine the file already uses) with `diagnostics = true` → `droppedClips == 0`. With it off → nil.
- [ ] **Step 2: Run it and see it fail; implement; run it and see it pass.**
- [ ] **Step 3: Measure.** `cd Packages/WilcoCore && swift run -c release wilco-bench --engines parakeet-v3 --channels 1,16,32 --duration 120 --diagnostics`, then the same without `--diagnostics`. Save the tables to `docs/benchmarks/2026-11-22-m1-max-diagnostics.md`. Pass: at 32 channels it still keeps up, CPU rises by a few percent at most, and clips dropped is 0 or near it. If not, change the meter to one clip every two minutes (a `clipEvery` minutes parameter on `ChannelMeter`, default 1) and re-measure.
- [ ] **Step 4: Docs.** SPEC.md, BENCHMARK.md, show review design pointer.
- [ ] **Step 5: Commit** `Bench: --diagnostics measures the meter and classifier; document the file`

---

After the last task: whole-branch review, merge `session-diagnostics` into `main`, then the end-of-session steps from `CLAUDE.md` (PROGRESS.md section marking the new checks **untuned**, README status table if it changed, push).
