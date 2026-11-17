# Long-talk Benchmark Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `wilco-bench --long-talk` plays 10–25 s of unbroken talking in room sound into every channel and fails the run when more than 10% of the words go missing.

**Architecture:** Passages are rendered by `say` and given room echo once, at load. A new scenario generator schedules them with a level per talk; `ChannelTrack` applies the level and a continuous hiss as it builds audio. "Words lost" comes from the deletions the scorer already counts, and long-talk runs add it to the "keeps up" verdict.

**Tech Stack:** Swift 6 (strict concurrency), Swift Testing, the `WilcoBench` library and `wilco-bench` tool in `Packages/WilcoCore`.

**Spec:** `docs/superpowers/specs/2026-11-16-long-talk-benchmark-design.md`

## Global Constraints

- The default sweep and `--conversation` must give the same audio and the same numbers as before: every new parameter defaults to "off".
- New `RunResult` fields are optional, so older `bench-*.json` reports still decode.
- Echoes: delays 30 / 70 / 130 / 210 ms, gains 0.5 / 0.35 / 0.25 / 0.15. Hiss ±0.002. Channel level ×0.1–×0.3. Loud-then-quiet talks: ×0.3, then ×0.06 from halfway.
- Quiet between talks: 3–8 s. Words-lost bar: 10%.
- Tests use Swift Testing. Tests that call `say` gate on `WILCO_ASR_TESTS`.
- Don't name the reference app. No new warnings.
- Run tests from `Packages/WilcoCore`: `swift test --filter <name>`.

## Review Focus

1. **A passage longer than the run** (`--duration 15`): no talk fits. The tool should stop with a message saying so, not report a clean empty run. → Task 4.
2. **`--long-talk` with `--conversation`:** stop with a message. → Task 4.
3. **A soft `say` voice at ×0.06** could sit under the segmenter's 0.005 absolute minimum and look like a lock-out that isn't one. → Task 2's gated coverage test runs every benchmark voice.
4. **Hiss must not depend on how the feeder chunks the track** (20 ms chunks with jitter), or two runs hear different audio. → Task 2.
5. **An old report file** without the new fields must decode and keep its old verdict. → Task 3.

## Files

| File | Change |
|---|---|
| `Sources/WilcoBench/RoomSound.swift` | New: echo treatment and frame-indexed hiss |
| `Sources/WilcoBench/ClipLibrary.swift` | `passages`; `synthesized` takes the texts to render |
| `Sources/WilcoBench/Scenario.swift` | `ScheduledUtterance.gain` / `quietFrom`; `Scenario.longTalk` / `hiss`; `generateLongTalks`; `ChannelTrack` applies them |
| `Sources/WilcoBench/BenchReport.swift` | `RunResult.longTalk`, `wordsLost`, verdict, column, notes |
| `Sources/WilcoBench/BenchRunner.swift` | Pass hiss to tracks; fill `longTalk` |
| `Sources/wilco-bench/main.swift` | `--long-talk` |
| `Tests/WilcoBenchTests/LongTalkTests.swift` | New |
| `Tests/WilcoTranscriptionTests/ContinuousSpeechSegmenterTests.swift` | Use `RoomSound` |
| `Package.swift` | `WilcoTranscriptionTests` depends on `WilcoBench` |
| `docs/BENCHMARK.md`, `docs/benchmarks/2026-11-16-m1-max-say-long-talk.md` | Docs and first results |

---

### Task 1: Room sound and passages

**Files:**
- Create: `Sources/WilcoBench/RoomSound.swift`, `Tests/WilcoBenchTests/LongTalkTests.swift`
- Modify: `Sources/WilcoBench/ClipLibrary.swift`, `Tests/WilcoTranscriptionTests/ContinuousSpeechSegmenterTests.swift`, `Package.swift`

**Interfaces — produces:**

```swift
public enum RoomSound {
    /// Echo delays in seconds and their gains.
    public static let echoes: [(delay: Double, gain: Float)]   // 0.03/0.5, 0.07/0.35, 0.13/0.25, 0.21/0.15
    public static let hissLevel: Float = 0.002
    /// `samples` with the echoes added. Longer than the input by the last echo's delay.
    public static func echoed(_ samples: [Float], sampleRate: Double) -> [Float]
    /// Uniform noise in ±level for one frame. A pure function of (seed, frame).
    public static func hiss(frame: Int, seed: UInt64, level: Float = hissLevel) -> Float
}

extension ClipLibrary {
    public static let passages: [String]
    // existing function gains a first parameter:
    public static func synthesized(
        _ texts: [String] = phrases, sampleRate: Double, cacheDirectory: URL, voiceLimit: Int = 4
    ) throws -> (clips: [BenchClip], voices: [String])
}
```

- [ ] **Step 1: Write failing tests** in `LongTalkTests.swift` (`@Suite struct LongTalkTests`):

```swift
@Test func echoesLandAtTheirDelays() {
    var impulse = [Float](repeating: 0, count: 100); impulse[0] = 1
    let out = RoomSound.echoed(impulse, sampleRate: 1_000)
    #expect(out.count == 100 + 210)
    #expect(out[0] == 1 && out[30] == 0.5 && out[70] == 0.35 && out[130] == 0.25 && out[210] == 0.15)
    #expect(out[31] == 0)
}

@Test func hissIsTheSameForTheSameFrame() {
    let a = (0..<1_000).map { RoomSound.hiss(frame: $0, seed: 7) }
    #expect(a == (0..<1_000).map { RoomSound.hiss(frame: $0, seed: 7) })
    #expect(a != (0..<1_000).map { RoomSound.hiss(frame: $0, seed: 8) })
    #expect(a.allSatisfy { abs($0) <= 0.002 })
    #expect(Set(a).count > 900)
}

@Test func passagesAreLongAndPlainWords() {
    #expect(ClipLibrary.passages.count >= 6)
    for passage in ClipLibrary.passages {
        let words = TranscriptNormalizer.words(passage)
        #expect((30...75).contains(words.count), "\(words.count) words")   // about 10–25 s
        #expect(!passage.contains(where: \.isNumber))
    }
}
```

- [ ] **Step 2: Run** `swift test --filter LongTalkTests`. Expected: fails to compile (`RoomSound` not found).
- [ ] **Step 3: Implement `RoomSound`.** `hiss` mixes `seed` and `frame` with the SplitMix64 finaliser already in `Scenario.swift` (one hash per frame, no stored state).
- [ ] **Step 4: Add `ClipLibrary.passages`.** Six to eight passages, each one or two long sentences joined with commas and "and"/"so"/"because" (full stops make `say` pause; keep to at most one inside a passage). Someone on comms explaining a problem or talking a crew through a sequence. No digits, no names, no unusual show terms: spell numbers as words. One passage is the sentence in `ContinuousSpeechSegmenterTests.sentence`, moved here; the test then reads `ClipLibrary.passages[0]`.
- [ ] **Step 5: Add the `texts` parameter to `synthesized`** in place of the hard-coded `phrases`. The cache key already includes the text.
- [ ] **Step 6: Point `ContinuousSpeechSegmenterTests.room` at `RoomSound`.** Add `"WilcoBench"` to the `WilcoTranscriptionTests` target's dependencies. `room(_:level:)` becomes `RoomSound.echoed`, × level, + `RoomSound.hiss(frame:seed: 1)`. Delete its own `Hiss` generator and echo table.
- [ ] **Step 7: Run** `swift test --filter LongTalkTests` and `WILCO_ASR_TESTS=1 swift test --filter ContinuousSpeechSegmenterTests`. Expected: all pass (the gated ones still ≥ 90%).
- [ ] **Step 8: Commit** — `Bench: room sound and long passages`.

---

### Task 2: Long-talk scenario and track levels

**Files:**
- Modify: `Sources/WilcoBench/Scenario.swift`, `Sources/WilcoBench/BenchRunner.swift`
- Test: `Tests/WilcoBenchTests/LongTalkTests.swift`, `Tests/WilcoTranscriptionTests/ContinuousSpeechSegmenterTests.swift`

**Interfaces — consumes:** `RoomSound.hiss(frame:seed:level:)`.

**Interfaces — produces:**

```swift
// ScheduledUtterance: two new optional fields, both defaulting to nil in init.
public var gain: Float?        // level the clip plays at; nil = 1
public var quietFrom: Double?  // seconds into the clip after which it plays at Scenario.quietGain

// Scenario
public var longTalk = false
public var hiss: Float = 0                       // ±level under the whole track; 0 = none
public static let talkGap = 3.0...8.0
public static let channelLevel: ClosedRange<Float> = 0.1...0.3
public static let loudGain: Float = 0.3
public static let quietGain: Float = 0.06
public static func generateLongTalks(
    channels channelCount: Int, clipDurations: [Double], duration: Double, seed: UInt64
) -> Scenario

// ChannelTrack
public init(utterances: [ScheduledUtterance], clips: [[Float]], sampleRate: Double,
            hiss: Float = 0, hissSeed: UInt64 = 0)
```

`generateLongTalks`: per channel (same per-channel seeding as `generate`), pick one level in `channelLevel`; first talk starts 0–3 s in; talks are random clips separated by a gap drawn from `talkGap`; about one talk in three is loud-then-quiet (`gain: loudGain`, `quietFrom: clip duration / 2`), the rest play at the channel level; only talks ending by `duration - minimumGap` are placed. Returns `longTalk: true`, `hiss: RoomSound.hissLevel`, `dutyCycle` = speech share as `generateConversations` computes it.

- [ ] **Step 1: Write failing tests:**

```swift
@Test func longTalksAreSeededSpacedAndWhole() {
    let durations = [12.0, 18.0, 24.0]
    let a = Scenario.generateLongTalks(channels: 8, clipDurations: durations, duration: 120, seed: 3)
    #expect(a == Scenario.generateLongTalks(channels: 8, clipDurations: durations, duration: 120, seed: 3))
    #expect(a.longTalk && a.hiss == 0.002)
    var quiet = 0, total = 0
    for channel in a.channels {
        #expect(!channel.isEmpty)
        for (talk, next) in zip(channel, channel.dropFirst()) {
            #expect((3.0...8.0).contains(next.start - talk.end))
        }
        #expect(channel.last!.end <= 120 - Scenario.minimumGap)
        let steady = Set(channel.filter { $0.quietFrom == nil }.map(\.gain))
        #expect(steady.count <= 1)                               // one level per channel
        for talk in channel {
            total += 1
            if let from = talk.quietFrom {
                quiet += 1
                #expect(talk.gain == 0.3 && from == talk.duration / 2)
            } else {
                #expect((0.1...0.3).contains(talk.gain!))
            }
        }
    }
    #expect(quiet > 0 && quiet < total / 2)
}

@Test func trackAppliesGainTheQuietHalfAndHiss() {
    let clip = [Float](repeating: 1, count: 1_000)
    let talk = ScheduledUtterance(clip: 0, start: 1, duration: 1, gain: 0.3, quietFrom: 0.5)
    let track = ChannelTrack(utterances: [talk], clips: [clip], sampleRate: 1_000, hiss: 0.002, hissSeed: 5)
    let all = track.samples(from: 0, count: 3_000)
    #expect(abs(all[1_100] - 0.3) <= 0.002 && abs(all[1_700] - 0.06) <= 0.002)
    #expect(all[500] != 0 && abs(all[500]) <= 0.002)             // hiss between talks
    // The same audio however it's chunked.
    let chunked = stride(from: 0, to: 3_000, by: 137).flatMap { track.samples(from: $0, count: min(137, 3_000 - $0)) }
    #expect(chunked == all)
}

@Test func defaultTrackIsUnchanged() {
    let clip = [Float](repeating: 0.5, count: 100)
    let track = ChannelTrack(utterances: [.init(clip: 0, start: 0, duration: 0.1)], clips: [clip], sampleRate: 1_000)
    #expect(track.samples(from: 0, count: 200) == clip + [Float](repeating: 0, count: 100))
}
```

- [ ] **Step 2: Run** `swift test --filter LongTalkTests`. Expected: compile failure on the new names.
- [ ] **Step 3: Implement** the fields, `generateLongTalks`, and the `ChannelTrack` changes. `ChannelTrack` stores gain and the quiet-from frame per placed clip. With `hiss == 0` and nil gains the output must be bit-identical to today's.
- [ ] **Step 4: In `BenchRunner.run`,** build each track with `hiss: scenario.hiss, hissSeed: UInt64(index)`.
- [ ] **Step 5: Run** `swift test --filter WilcoBenchTests`. Expected: all pass, including the existing suite.
- [ ] **Step 6: Gated coverage test for every voice** (Review Focus 3), in `ContinuousSpeechSegmenterTests`:

```swift
@Test(.enabled(if: asrTests), arguments: ["Samantha", "Daniel", "Karen", "Moira"])
func everyBenchVoiceSurvivesTheQuietHalf(voice: String) throws {
    let clip = RoomSound.echoed(try sayClip(ClipLibrary.passages[0], voice: sayVoice(voice)), sampleRate: Self.rate)
    let half = clip.count / 2
    let audio = clip.enumerated().map { $1 * ($0 < half ? 0.3 : 0.06) + RoomSound.hiss(frame: $0, seed: 1) }
    #expect(Self.coverage(of: audio) >= 0.9)
}
```

Run with `WILCO_ASR_TESTS=1`. If a voice fails here, the fault is the level, not the segmenter: raise `quietGain` until all four pass and note the value in the spec.
- [ ] **Step 7: Commit** — `Bench: long-talk scenario with levels and hiss`.

---

### Task 3: Words lost and the verdict

**Files:**
- Modify: `Sources/WilcoBench/BenchReport.swift`, `Sources/WilcoBench/BenchRunner.swift`
- Test: `Tests/WilcoBenchTests/LongTalkTests.swift`

**Interfaces — produces:**

```swift
// RunResult
public var longTalk: Bool?                 // nil in older reports and other modes
public var wordsLost: Double { get }       // deletions / referenceWords; 0 with no reference words
public static let acceptableWordsLost = 0.10
// cuesKeepUp gains: && (longTalk != true || wordsLost <= Self.acceptableWordsLost)

// BenchReport
public static func tableHeader(longTalk: Bool) -> String    // adds a "Words lost" column after WER
public static func tableRow(_ r: RunResult) -> String       // adds the cell when r.longTalk == true
```

Keep the existing `tableHeader` property as `tableHeader(longTalk: false)`. `markdown()` uses the long-talk header when its results are long-talk runs and adds one note line: what "words lost" is and the 10% bar.

- [ ] **Step 1: Write failing tests.**
  - `wordsLostFailsOnlyLongTalkRuns`: a `RunResult` that otherwise keeps up, with `wordErrors: .init(deletions: 20, referenceWords: 100)`. `wordsLost == 0.2`; `keepsUp` is true with `longTalk == nil`, false with `longTalk == true`; with `deletions: 10` and `longTalk == true` it's true.
  - `olderReportsStillDecode`: encode a `RunResult`, strip the `longTalk` key from the JSON, decode; `longTalk == nil` and `keepsUp` unchanged.
  - `longTalkRowHasWordsLost`: `tableRow` of a long-talk result contains `"20.0%"` and has one more cell than a plain row; the header from `tableHeader(longTalk: true)` contains `"Words lost"`.
  - `anEngineThatDropsTheSecondHalfDoesNotKeepUp` (`.timeLimit(.minutes(1))`): two 3 s clips of eight words each at 16 kHz, `generateLongTalks(channels: 2, clipDurations: [3, 3], duration: 20, seed: 1)`, a test-double transcriber modelled on `EchoTranscriber` in `BenchLogicTests.swift` that emits only the first half of each talk's words as one final line when the talk ends. Expect `result.longTalk == true`, `result.missed == 0`, `result.wordsLost > 0.4`, `!result.keepsUp`. A second run with the double emitting every word: `result.keepsUp`.
- [ ] **Step 2: Run** `swift test --filter LongTalkTests`. Expected: compile failure, then the last test failing on `keepsUp`.
- [ ] **Step 3: Implement** in `BenchReport.swift`; in `BenchRunner.run` set `longTalk: scenario.longTalk ? true : nil`.
- [ ] **Step 4: Run** `swift test --filter WilcoBenchTests`. Expected: all pass.
- [ ] **Step 5: Commit** — `Bench: words lost, and long-talk runs fail on it`.

---

### Task 4: The `--long-talk` flag, docs and first results

**Files:**
- Modify: `Sources/wilco-bench/main.swift`, `docs/BENCHMARK.md`
- Create: `docs/benchmarks/2026-11-16-m1-max-say-long-talk.md`

**Interfaces — consumes:** `ClipLibrary.synthesized(ClipLibrary.passages, …)`, `RoomSound.echoed`, `Scenario.generateLongTalks`, `BenchReport.tableHeader(longTalk:)`.

- [ ] **Step 1: Add the flag.** Help text: `--long-talk  Channels hold 10–25 s of unbroken talking in room sound; fails when over 10% of words are lost.`
  - With `--conversation`: `fail("--long-talk and --conversation can't be combined")`.
  - Clips: without `--corpus`, render `ClipLibrary.passages` and pass each clip's samples through `RoomSound.echoed`. With `--corpus`, use the recordings as they are (they have their own room); the scenario still applies levels and hiss.
  - Scenario: `generateLongTalks`. If `scenario.utteranceCount == 0`: `fail("no talk fits in a \(Int(options.duration)) s run; the shortest is \(Int(shortest)) s. Use a longer --duration")` (Review Focus 1).
  - `--duty` is ignored; the start-up log line says "long talks" in place of the talk-time share. Print `tableHeader(longTalk:)`. The corpus name in the report ends with ", long talks".
- [ ] **Step 2: Check the guards by hand:**
  `swift run -c release wilco-bench --long-talk --conversation` → the "can't be combined" message, exit non-zero.
  `swift run -c release wilco-bench --long-talk --duration 8 --engines whisper-base --channels 1` → the "no talk fits" message.
- [ ] **Step 3: Run it.** On AC power with the lid open:
  `caffeinate -dims swift run -c release wilco-bench --long-talk --duration 120 --engines parakeet-v3,whisper-base,apple-longform --channels 1,8,32`
  Expected: Parakeet and Whisper base keep up with words lost well under 10%. If one doesn't, read the saved samples before changing anything: decide whether it is the segmenter, the levels (Task 2 step 6) or the engine, and report it rather than tuning until it passes.
- [ ] **Step 4: Prove the mode catches the bug.** Put the old rule back in the working tree only:
  `git show c2b0df8^:Packages/WilcoCore/Sources/WilcoCore/UtteranceSegmenter.swift > Sources/WilcoCore/UtteranceSegmenter.swift` (check the path with `git show --stat c2b0df8` first), run
  `swift run -c release wilco-bench --long-talk --duration 120 --engines parakeet-v3 --channels 8`.
  Expected: words lost far above 10%, Keeps up **no**. Then `git checkout Sources/WilcoCore/UtteranceSegmenter.swift` and confirm `git status` is clean for that file. If the old rule passes, the mode isn't doing its job: stop and report.
- [ ] **Step 5: Write `docs/benchmarks/2026-11-16-m1-max-say-long-talk.md`** in the style of the other files there: the command, the table from step 3, the old-rule row from step 4, and two or three plain findings.
- [ ] **Step 6: Add a "Long talks" section to `docs/BENCHMARK.md`** after "Voice changes": what the mode plays, what "words lost" means, the 10% bar, that `say` passages are still a best case, and that `--corpus` recordings are used as they are.
- [ ] **Step 7: Run the whole package's tests** — `swift test`. Expected: all pass, no new warnings.
- [ ] **Step 8: Commit** — `Bench: --long-talk mode, docs and first results`.
