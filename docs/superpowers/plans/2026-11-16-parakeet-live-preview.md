# Parakeet Live Preview Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** On Parakeet channels set to "Fast, then corrected", show italic words for the utterance in progress, then the final line at the pause, without delaying final lines.

**Architecture:** While someone is talking, the channel's existing pump loop (`UtteranceChannelTranscriber`) transcribes the audio so far about every 0.5 s and sends it as a volatile event. A shared gate in `ParakeetModelStore` lets a preview run only when no final line is in flight, and returns nil otherwise, so final lines are never kept waiting behind previews. The per-channel Latency picker, already stored in every show, switches previews on and off.

**Tech Stack:** Swift 6 (strict concurrency), Swift Testing, FluidAudio (Parakeet TDT v3), SwiftUI.

**Spec:** `docs/superpowers/specs/2026-11-16-parakeet-live-preview-design.md`

## Global Constraints

- Swift 6 language mode. Fix warnings; don't silence them.
- Deployment target macOS 15. CI builds with Xcode 26.6: nothing here may need the Xcode 27 / macOS 27 SDK.
- Tests use Swift Testing (`@Suite`, `@Test`), not XCTest. Tests that need real models use `.enabled(if: ProcessInfo.processInfo.environment["WILCO_ASR_TESTS"] != nil)`.
- No file format change. `ChannelConfig.latencyProfile` already decodes with a `.leadAndCorrect` default.
- Previews are display-only. Rules, OSC, MIDI, MOS, HTTP, peers and the session file still get only final lines. `AppModel.swift:277` already drops non-final events; don't change that.
- Don't name or version the reference app anywhere (code, comments, docs, commits).
- The audio capture callback is untouched. Preview work runs in the pump task, never on the audio thread.
- Preview values: interval **500 ms**; minimum audio before the first preview **0.5 s**; no vocabulary boosting on previews.
- Benchmark pass: `parakeet-v3-preview` keeps up at 32 channels, and its final p95 is within **0.25 s** of `parakeet-v3` at the same channel count.

## Review Focus

1. **An utterance cut at the 20 s maximum while speech goes on:** the previews carry on for the next chunk with its own start offset, and no preview of the earlier chunk arrives after that chunk's final. Test in Task 3.
2. **A short call ("Go.", under 0.5 s of speech):** no preview is attempted, and the final line still arrives. Test in Task 3.
3. **Capture stopped mid-utterance:** `stop()` flushes the final line, and no volatile event follows it. Test in Task 3.
4. **A Parakeet model that's missing or fails mid-session:** `preview` returns nil without throwing, and the channel's status doesn't change. Test in Task 2.
5. **A final transcription that throws:** the gate still counts that final as finished, so previews resume on every channel. Test in Task 2.

---

### Task 1: Segmenter exposes the utterance in progress

**Files:**
- Modify: `Packages/WilcoCore/Sources/WilcoCore/Transcription/UtteranceSegmenter.swift`
- Test: `Packages/WilcoCore/Tests/WilcoCoreTests/TranscriptionLogicTests.swift` (suite `UtteranceSegmenterTests`)

**Interfaces:**
- Produces: `public var inProgress: UtteranceSegmenter.Utterance? { get }` returns nil when not in speech; otherwise the samples so far (pre-roll included) and `startOffset = Double(currentStart) / sampleRate`.

- [ ] **Step 1: Write the failing tests** in `UtteranceSegmenterTests`, using the suite's existing speech/silence helpers:

```swift
@Test func inProgressIsNilInSilence() {
    var segmenter = UtteranceSegmenter(sampleRate: rate)
    _ = segmenter.append(silence(seconds: 1))
    #expect(segmenter.inProgress == nil)
}

@Test func inProgressGrowsDuringSpeechAndClearsAfterTheCut() throws {
    var segmenter = UtteranceSegmenter(sampleRate: rate)
    _ = segmenter.append(silence(seconds: 1) + speech(seconds: 0.5))
    let early = try #require(segmenter.inProgress)
    _ = segmenter.append(speech(seconds: 0.5))
    let later = try #require(segmenter.inProgress)
    #expect(later.samples.count > early.samples.count)
    #expect(later.startOffset == early.startOffset)
    #expect(abs(early.startOffset - 0.7) < 0.03)   // 1 s silence less 0.3 s pre-roll
    let finished = segmenter.append(silence(seconds: 1))
    #expect(finished.count == 1)
    #expect(segmenter.inProgress == nil)
}

@Test func inProgressRestartsAfterAMaximumLengthCut() throws {
    var segmenter = UtteranceSegmenter(sampleRate: rate)
    segmenter.maximumLength = 2
    let cut = segmenter.append(speech(seconds: 2.5))
    #expect(cut.count == 1)
    let next = try #require(segmenter.inProgress)
    #expect(next.startOffset >= 1.99)
    #expect(Double(next.samples.count) / rate < 0.6)
}
```

If the suite has no `silence`/`speech` helpers under those names, use the ones it has. Don't add duplicates.

- [ ] **Step 2: Run them and confirm they fail**

Run: `cd Packages/WilcoCore && swift test --filter UtteranceSegmenterTests`
Expected: compile error, `value of type 'UtteranceSegmenter' has no member 'inProgress'`.

- [ ] **Step 3: Add `inProgress`** as a computed property built from `inSpeech`, `current` and `currentStart`.

- [ ] **Step 4: Run them and confirm they pass**

Run: `cd Packages/WilcoCore && swift test --filter UtteranceSegmenterTests`
Expected: all pass, the existing segmenter tests included.

- [ ] **Step 5: Commit**

```bash
git add Packages/WilcoCore/Sources/WilcoCore/Transcription/UtteranceSegmenter.swift Packages/WilcoCore/Tests/WilcoCoreTests/TranscriptionLogicTests.swift
git commit -m "Segmenter: expose the utterance in progress"
```

---

### Task 2: Preview gate and `preview()` on recognizers

**Files:**
- Create: `Packages/WilcoCore/Sources/WilcoTranscription/PreviewGate.swift`
- Modify: `Packages/WilcoCore/Sources/WilcoTranscription/UtteranceChannelTranscriber.swift` (protocol only)
- Modify: `Packages/WilcoCore/Sources/WilcoTranscription/ParakeetModelStore.swift`
- Modify: `Packages/WilcoCore/Sources/WilcoTranscription/ParakeetRecognizer.swift`
- Test: `Packages/WilcoCore/Tests/WilcoTranscriptionTests/ParakeetTests.swift`

**Interfaces:**
- Produces:
  - `public protocol UtteranceRecognizer` gains `func preview(_ samples: [Float]) async -> Recognition?`, with a default implementation in an extension that returns `nil`.
  - `public actor PreviewGate` with `init()`, `func beginFinal()`, `func endFinal()`, `func tryBeginPreview() -> Bool`, `func endPreview()`, and, for tests, `var finalsInFlight: Int { get }`.
  - `ParakeetModelStore` gains `nonisolated let previewGate: PreviewGate`.
  - `ParakeetRecognizer.preview(_:)`.

Gate rules: `beginFinal`/`endFinal` keep a count and never wait. Final lines reach the model just as they do today. A final that arrives while a preview is already running waits behind that one preview inside `AsrManager`, a single short transcription. That is the most a final can be held up; the benchmark in Task 5 measures it. `tryBeginPreview()` returns true, and marks a preview as running, only if no final is in flight and no other preview is running. Otherwise it returns false at once.

`ParakeetRecognizer.recognize` calls `beginFinal()` **before** `store.manager()`, and calls `endFinal()` on every exit path, including throws. It can't use `defer` around an actor call, so it catches, ends the final, and rethrows. `preview` calls `tryBeginPreview()`, returns nil if that fails, and otherwise transcribes with the same short-clip padding as `recognize`. It doesn't use the booster. It catches every error and returns nil, and calls `endPreview()` on every path.

- [ ] **Step 1: Write the failing tests** in `ParakeetTests`:

```swift
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
    await gate.beginFinal()            // returns at once
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
    #expect(await ParakeetRecognizer(store: store, language: .english).preview([Float](repeating: 0, count: 16_000)) == nil)
    #expect(await store.previewGate.tryBeginPreview())   // the failed preview ended
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["WILCO_ASR_TESTS"] != nil))
func previewsASpokenCall() async throws {
    let samples = try sayClip("Standby lighting cue forty two")
    let half = Array(samples.prefix(samples.count / 2))
    let preview = await ParakeetRecognizer(store: Self.testStore(), language: .english).preview(half)
    #expect(preview?.text.isEmpty == false)
}
```

- [ ] **Step 2: Run them and confirm they fail**

Run: `cd Packages/WilcoCore && swift test --filter ParakeetTests`
Expected: compile errors for `PreviewGate`, `previewGate` and `preview`.

- [ ] **Step 3: Implement** `PreviewGate`, the protocol requirement with its nil default, `previewGate` on the store, and `ParakeetRecognizer.recognize`/`preview` following the rules above. Pull the short-clip padding into one private helper shared by `recognize` and `preview`.

- [ ] **Step 4: Run them and confirm they pass, including the existing transcriber tests**

Run: `cd Packages/WilcoCore && swift test --filter 'ParakeetTests|UtteranceTranscriberTests'`
Expected: all pass. Then run `WILCO_ASR_TESTS=1 swift test --filter previewsASpokenCall` (with the Parakeet model installed). Expected: pass.

- [ ] **Step 5: Commit**

```bash
git add Packages/WilcoCore/Sources/WilcoTranscription Packages/WilcoCore/Tests/WilcoTranscriptionTests/ParakeetTests.swift
git commit -m "Parakeet: preview gate that never holds up final lines"
```

---

### Task 3: Transcriber sends previews while someone talks

**Files:**
- Modify: `Packages/WilcoCore/Sources/WilcoTranscription/UtteranceChannelTranscriber.swift`
- Test: `Packages/WilcoCore/Tests/WilcoTranscriptionTests/UtteranceTranscriberTests.swift`

**Interfaces:**
- Consumes: `UtteranceSegmenter.inProgress` (Task 1) and `UtteranceRecognizer.preview(_:)` (Task 2).
- Produces: `UtteranceChannelTranscriber.init(..., previewInterval: Duration? = nil, onEvent:, onStatus:)`. The new parameter comes after `voiceprints`. `nil` means no previews, so every existing caller keeps today's behaviour.

Behaviour in `run()`, after handing finished utterances to `transcribe` on each pump pass: if `previewInterval` isn't nil, `segmenter.inProgress` has at least 0.5 s of 16 kHz audio, and at least `previewInterval` has passed (by `ContinuousClock`) since the last attempt on this utterance, then await `recognizer.preview(samples)`. Record the attempt time whatever the result. Reset the timer when `inProgress.startOffset` changes. A non-empty trimmed result is sent as `TranscriptionEvent(channelID:, text:, isFinal: false, sessionOffset: sessionOffset + startOffset, confidence: recognition.confidence)`. Nil or empty results send nothing.

- [ ] **Step 1: Write the failing tests.** Extend `FakeRecognizer` with `let previews = Mutex(0)` and a `preview` that increments it and returns `Recognition(text: "standby", confidence: nil)`, then add:

```swift
@Test(.timeLimit(.minutes(1))) func previewsWhileTalkingThenSendsTheFinalLine() async throws {
    // 2.5 s of speech, then a pause. previewInterval: .milliseconds(500).
    // Wait for a final event, then stop.
    let events = /* log */
    let finalIndex = try #require(events.firstIndex { $0.isFinal })
    #expect(events[..<finalIndex].contains { !$0.isFinal && $0.text == "standby" })
    #expect(!events[(finalIndex + 1)...].contains { !$0.isFinal })
    #expect(events.filter { !$0.isFinal }.allSatisfy { abs($0.sessionOffset - events[finalIndex].sessionOffset) < 0.01 })
}

@Test(.timeLimit(.minutes(1))) func noPreviewsWhenOff() async throws {
    // Same audio, previewInterval: nil.
    #expect(recognizer.previews.withLock { $0 } == 0)
    #expect(log.events.withLock { $0 }.allSatisfy(\.isFinal))
}

@Test(.timeLimit(.minutes(1))) func aShortCallIsNotPreviewed() async throws {
    // 0.3 s of speech, then a pause. previewInterval: .milliseconds(500).
    #expect(recognizer.previews.withLock { $0 } == 0)
    #expect(log.events.withLock { $0 }.count == 1)
}

@Test(.timeLimit(.minutes(1))) func noPreviewAfterTheFinalWhenStoppedMidCall() async throws {
    // 2 s of speech with no pause, wait ~1.5 s, then stop().
    let events = log.events.withLock { $0 }
    #expect(events.last?.isFinal == true)
}

@Test(.timeLimit(.minutes(1))) func previewsFollowAMaximumLengthCut() async throws {
    // A transcriber whose segmenter cuts at 2 s needs a seam: add an
    // internal `maximumUtteranceLength: Double = 20` init parameter,
    // passed to the segmenter, for this test.
    // 3.5 s of continuous speech, then a pause.
    // Expect two finals; every volatile event before the second final and
    // after the first carries the second utterance's sessionOffset.
}
```

Write each body like `cutsAtPausesAndSendsFinalLines`: the same ring, `Log`, `speech(seconds:rate:)` and polling loop. The assertions shown are the ones that must hold.

- [ ] **Step 2: Run them and confirm they fail**

Run: `cd Packages/WilcoCore && swift test --filter UtteranceTranscriberTests`
Expected: compile error, `extra argument 'previewInterval'`.

- [ ] **Step 3: Implement** the `previewInterval` and internal `maximumUtteranceLength` parameters and the preview step in `run()`, as described above. Update the type's doc comment: lines still arrive final, with optional volatile previews.

- [ ] **Step 4: Run them and confirm they pass**

Run: `cd Packages/WilcoCore && swift test --filter UtteranceTranscriberTests`
Expected: all pass, including `cutsAtPausesAndSendsFinalLines` unchanged.

- [ ] **Step 5: Commit**

```bash
git add Packages/WilcoCore/Sources/WilcoTranscription/UtteranceChannelTranscriber.swift Packages/WilcoCore/Tests/WilcoTranscriptionTests/UtteranceTranscriberTests.swift
git commit -m "Utterance transcriber: volatile previews while someone talks"
```

---

### Task 4: Wire it into the app (factory, inspector, SPEC)

**Files:**
- Modify: `Packages/WilcoCore/Sources/WilcoTranscription/ChannelTranscriber.swift` (`ChannelTranscribers`)
- Modify: `Wilco/Inspector/ChannelInspector.swift:184-189`
- Modify: `docs/SPEC.md` §6
- Test: `Packages/WilcoCore/Tests/WilcoTranscriptionTests/ParakeetTests.swift`

**Interfaces:**
- Consumes: `UtteranceChannelTranscriber.init(previewInterval:)` (Task 3).
- Produces: `public static func previewInterval(for configuration: TranscriberConfiguration) -> Duration?` on `ChannelTranscribers`. It returns `.milliseconds(500)` when `engine == .parakeet && latencyProfile == .leadAndCorrect`, and nil otherwise. `make` passes it to the Parakeet transcriber.

- [ ] **Step 1: Write the failing test**

```swift
@Test func previewsFollowTheLatencyPicker() {
    func configuration(_ engine: SpeechEngine, _ profile: SpeechLatencyProfile) -> TranscriberConfiguration {
        TranscriberConfiguration(channel: ChannelConfig(engine: engine, latencyProfile: profile), show: ShowDocument())
    }
    #expect(ChannelTranscribers.previewInterval(for: configuration(.parakeet, .leadAndCorrect)) == .milliseconds(500))
    #expect(ChannelTranscribers.previewInterval(for: configuration(.parakeet, .single)) == nil)
    #expect(ChannelTranscribers.previewInterval(for: configuration(.whisper, .leadAndCorrect)) == nil)
}
```

Use whatever `ChannelConfig` initializer arguments are required. Only `engine` and `latencyProfile` matter here.

- [ ] **Step 2: Run it and confirm it fails**

Run: `cd Packages/WilcoCore && swift test --filter previewsFollowTheLatencyPicker`
Expected: compile error, `type 'ChannelTranscribers' has no member 'previewInterval'`.

- [ ] **Step 3: Implement** `previewInterval(for:)` and pass it from `make`.

- [ ] **Step 4: Update the inspector.** Change `.disabled(!channel.engine.isApple)` to `.disabled(channel.engine == .whisper)`. Change `.help` to exactly: `"Shows words as they are spoken, then replaces them with the finished line. Uses more CPU per channel."`

- [ ] **Step 5: Update SPEC §6.** In the `leadAndCorrect` paragraph, add that on Parakeet channels the same model transcribes the utterance so far about every 0.5 s for the italic preview, final lines take priority, and previews are skipped while any final line is in flight. In the engine table's Parakeet row, add "Live preview with *Fast, then corrected*."

- [ ] **Step 6: Run the package tests and the app build**

Run: `cd Packages/WilcoCore && swift test`
Expected: all pass; the gated tests skip.
Run: `xcodebuild build -project Wilco.xcodeproj -scheme Wilco -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY=""` from the repo root.
Expected: `** BUILD SUCCEEDED **`, with no new warnings in the files touched.

- [ ] **Step 7: Commit**

```bash
git add Packages/WilcoCore/Sources/WilcoTranscription/ChannelTranscriber.swift Packages/WilcoCore/Tests/WilcoTranscriptionTests/ParakeetTests.swift Wilco/Inspector/ChannelInspector.swift docs/SPEC.md
git commit -m "Parakeet channels preview words with Fast, then corrected"
```

---

### Task 5: Benchmark engines and the 32-channel check

**Files:**
- Modify: `Packages/WilcoCore/Sources/WilcoBench/ParakeetEngine.swift`
- Modify: `Packages/WilcoCore/Sources/WilcoBench/BenchEngine.swift` (`builtIn` list)
- Modify: `docs/BENCHMARK.md` (engine list, if it names engines)
- Create: `docs/benchmarks/2026-11-16-m1-max-say-preview.md` and `.json` (copied from the run's `--out` folder)

**Interfaces:**
- Consumes: `UtteranceChannelTranscriber.init(previewInterval:)` (Task 3). Use `.milliseconds(500)`, the same value as `ChannelTranscribers.previewInterval`.
- Produces: engines `parakeet-v3-preview` and `parakeet-v3-preview-voices`. Build them like `parakeet-v3` and `parakeet-v3-voices`, with previews on. Give the private `factory(recognizer:)` helper a `previewInterval: Duration? = nil` parameter rather than copying it.

- [ ] **Step 1: Add the two engines** with summaries "Parakeet TDT 0.6B v3 with live preview (fast, then corrected)" and "... with live preview and voice changes". Add them to `builtIn` after `parakeet` and `parakeetVoices` respectively.

- [ ] **Step 2: Check they're listed**

Run: `cd Packages/WilcoCore && swift run -c release wilco-bench --list`
Expected: both new ids appear, available on this Mac.

- [ ] **Step 3: Run the channel sweep** (quit the reference app and Wilco first)

Run: `swift run -c release wilco-bench --engines parakeet-v3,parakeet-v3-preview --channels 1,8,16,32`
Expected: `parakeet-v3-preview` keeps up ("yes") at 32, and its final p95 is within 0.25 s of `parakeet-v3` at every channel count. Also check that `parakeet-v3` (finals now go through the gate) stays near the 2026-11-16 baseline's final p95.

- [ ] **Step 4: Run the conversation check**

Run: `swift run -c release wilco-bench --conversation --engines parakeet-v3-voices,parakeet-v3-preview-voices --channels 32 --voice-threshold 0.5`
Expected: both keep up (final and display), and final p95 is within 0.25 s.

- [ ] **Step 5: If either check fails, stop.** Report the numbers to the user with the spec's fallbacks (a 1 s interval, then a limit on previews while finals are in flight, then defaulting Parakeet to `single`). Don't pick one yourself.

- [ ] **Step 6: Save the baseline.** Copy the run's report into `docs/benchmarks/` under the name above, adding a short note at the top in the style of the other baselines: what was compared, the pass bar, the result.

- [ ] **Step 7: Commit**

```bash
git add Packages/WilcoCore/Sources/WilcoBench docs/BENCHMARK.md docs/benchmarks/2026-11-16-m1-max-say-preview.*
git commit -m "Bench: Parakeet live preview engines and 32-channel baseline"
```

---

### Task 6: Session log and push

**Files:**
- Modify: `docs/PROGRESS.md`, `README.md` (status table, if it lists engine features)

- [ ] **Step 1:** Add a dated `2026-11-16` section to the end of `PROGRESS.md` in its existing plain style: the feature, the benchmark result, and next steps. Call the feature **tested**, not verified, until the user has tried it in the app. A next step is for the user to try a Parakeet channel on "Fast, then corrected" in the app.
- [ ] **Step 2:** Run `swift test` once more. Expected: all pass.
- [ ] **Step 3:** Commit only the feature's files. Leave the user's other uncommitted changes alone. Then push to `main` after the user confirms.

```bash
git add docs/PROGRESS.md README.md
git commit -m "PROGRESS: Parakeet live preview"
```
