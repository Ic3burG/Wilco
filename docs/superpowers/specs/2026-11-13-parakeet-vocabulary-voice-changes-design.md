# Parakeet, vocabulary and voice changes: design

2026-11-13. Status: reviewed; awaiting the user's approval.

## Why

Two separate needs, built in one project because they share FluidAudio and
the same audio path.

1. **A better speech engine.** The 2026-11-13 benchmark
   (`docs/benchmarks/2026-11-13-m1-max-say.md`) found Parakeet TDT the most
   accurate engine that keeps up at 32 channels (3–4% WER, 0.77 s p95), and
   the only one that keeps up at 64. A show's vocabulary (cue names,
   department names, rule phrases) matters, so Parakeet must honour it from
   the start, as Apple's engines and Whisper already do.
2. **Seeing call and response.** One comms channel can carry up to 40
   voices. Today its transcript reads as one stream, so the user can't see
   where one person stops and another answers. They want each change of
   voice to show, and in a multi-party exchange to tell a third or fourth
   voice from the first two. Names don't matter.

The user expects to tune much of this against real shows, so the work
should leave a solid, measurable foundation rather than fixed guesses.

## Goals

- Parakeet TDT 0.6B **v3** as a fourth engine, chosen per channel like the
  others, with its model installed from Settings → Languages.
- Parakeet channels use the show's vocabulary
  (`ShowDocument.vocabulary(for:)`), through FluidAudio's CTC vocabulary
  boosting.
- **Voice changes** on every engine: each final line is marked with a
  letter (A, B, C…) for the voice that spoke it within the current
  exchange. A change of voice in the middle of what would have been one
  line splits it into two lines.
- Letters show in the transcript and in reports (HTML, SRT, VTT).
- `wilco-bench` measures voice-change accuracy and its CPU cost, so the
  feature is tuned on numbers.

## Non-goals

- Naming speakers, or recognising the same person across exchanges or
  sessions ("saved voices"). The foundation should allow it later; it is
  not built now.
- A v2/v3 picker. v3 only for now (it tied v2 on English and covers 25
  languages). A picker can follow if real audio favours v2.
- Rules that fire on a particular voice.
- Overlapping speech handled specially. Two people talking at once gets
  whichever letter the stronger voice matches.

## Anti-goals (would count as failure even if it works)

- **Breaking 32 channels.** A channel with Parakeet, vocabulary and voice
  changes all on must still keep up at 32 channels on the M1 Max in
  `wilco-bench`. If voice changes can't, they stay off by default and the
  limit is documented, rather than slowing transcription.
- **Storing voiceprints.** Speaker embeddings are biometric data. They live
  in memory for the current exchange only and are never written to disk,
  logs or exports.
- **Breaking old files.** Every existing `.wilco` show and `.jsonl`
  transcript must keep opening, and old builds should not choke on new
  ones where avoidable.
- **Letters that flicker.** A line's letter is fixed once the line is
  final; it is never rewritten later.

## Constraints

- Deployment target macOS 15; CI builds with Xcode 26.6. FluidAudio 0.18.3
  supports macOS 14+, so no availability guards are needed for it. It is
  Apache-2.0; the Parakeet and CTC models are CC-BY-4.0 and need
  attribution (an Acknowledgements entry in the app).
- The audio thread is real-time. `AudioRingBuffer` is single-producer,
  single-consumer: the channel's transcriber is its only reader. Voice
  analysis must take its audio from the transcriber, not open a second
  reader.
- Strings from speech are untrusted (already handled downstream).
- Swift 6 strict concurrency, no silenced warnings. New logic and tests go
  in the package; the app target stays thin.
- FluidAudio stays pinned (`exact: "0.18.3"`); its API changes between 0.x
  releases.

## Approaches considered (voice changes)

- **A. Compare voiceprints (chosen).** A small speaker-embedding model
  (WeSpeaker, 256 numbers per print, shipped with FluidAudio's diarizer)
  turns ~1.5 s of speech into a voiceprint. Prints taken through each
  utterance are compared with each other and with the voices already heard
  in the exchange. Answers "same voice or not?" directly, costs the same
  for 2 voices or 40, and has the best chance at 32 channels.
- **B. A live diarizer per channel (Sortformer or LS-EEND), using only its
  change points.** Better with overlapping speech, but 32 copies of a
  heavier model running constantly, designed for 4–10 speakers, and
  LS-EEND has more false alarms. Rejected as too heavy for the 32-channel
  requirement.
- **C. One voiceprint per line, no splitting.** Cheapest, but a quick
  "standing by" that lands in the same line as the call goes unmarked, and
  that's the exchange the user most wants to see. Rejected.

The user picked A, and asked that a third or fourth voice be told apart
from the first two within an exchange.

## Design

### Part 1: Parakeet engine

- `SpeechEngine` gains `case parakeet`. Decoding must survive a show
  saved by a newer build with an engine this build doesn't know: an
  unknown `engine` value decodes as the default (`.longForm`, or
  `.whisper` before macOS 26) instead of failing the whole show. Test with
  a fixture.
- `ChannelTranscribers.make` builds an `UtteranceChannelTranscriber` with
  a Parakeet recognizer for `.parakeet`. The recognizer and the model
  loader (`ParakeetModel`, currently in `WilcoBench/ParakeetEngine.swift`)
  move into `WilcoTranscription`, which takes the FluidAudio dependency.
  The app shares one loaded model across channels, as it does
  `WhisperModelStore`.
- Models live under `DataLocations` (`…/Wilco/ParakeetModels`), not
  FluidAudio's default folder, so Wilco owns and can remove them.
- **Language.** v3 detects the spoken language itself among its 25. The
  channel's language menu for Parakeet offers "Detect Automatically" plus
  those 25; a chosen language is a hint only if FluidAudio supports one
  (builder to check), otherwise the menu shows only "Detect
  Automatically" and explains why. Translate to English stays Whisper
  only.
- **Settings → Languages** gets a "Parakeet Model" section modelled on the
  Whisper one: status, Install, Remove, size on disk. `ModelInstaller.Item`
  gains `.parakeet`. The Speech Models list shows Parakeet channels against
  that one model, as it does Whisper.
- **Inspector:** "Parakeet" in the engine picker, with a short help line.
- Acknowledgements: FluidAudio (Apache-2.0), Parakeet and CTC models
  (CC-BY-4.0, NVIDIA).

### Part 2: Vocabulary for Parakeet

- FluidAudio's "Approach 2": a separate CTC encoder (~130 MB) spots the
  vocabulary in each utterance's audio and rescores Parakeet's transcript.
  It needs Parakeet's token timings, which `AsrManager.transcribe`
  returns.
- The vocabulary comes from `ShowDocument.vocabulary(for:)` (global terms,
  channel terms, rule phrases), already in `TranscriberConfiguration`.
  A vocabulary change restarts the channel, as it does today.
- Use FluidAudio's preflight (`hasCTCRescoringCandidates`) so utterances
  with no candidate term skip the CTC pass.
- Start from the conservative thresholds FluidAudio recommends for
  dictation-style use (fewer wrong replacements, more misses). A wrong cue
  number is worse than a missed one.
- The CTC model downloads with the Parakeet model (one Install button) and
  loads only when the channel has vocabulary.
- **English only.** The CTC encoder and its tokenizer are English, so
  boosting runs only when the channel's language is English. Parakeet
  channels default to English (not Detect Automatically). On any other
  language, or Detect Automatically, boosting is off and the Inspector says
  "Vocabulary applies to English channels only." (My call: avoids wrong
  replacements in non-English speech.)
- **Note on the preflight:** in FluidAudio 0.18.3, with 10 or fewer terms
  and spotter rescue on (the default), `hasCTCRescoringCandidates` always
  returns true, so small vocabularies never skip the CTC pass. Measure the
  real cost; don't count on the preflight.
- **If it doesn't keep up at 32 channels (user's decision):** vocabulary
  becomes a per-channel switch in the Inspector
  (`ChannelConfig.usesVocabulary`, decoded with a default), so it runs only
  on the lines where cue words matter (SM, calling lines). Default on for a
  channel's first Parakeet use if the benchmark allows it at 32 channels
  with every channel on; otherwise default off. Turning off spotter rescue
  was considered and rejected (catches fewer terms everywhere).
- `wilco-bench` gets a `parakeet-v3-vocab` engine and a vocabulary in its
  scenario (cue words the `say` clips use), reporting WER both ways.

### Part 3: Voice changes

**Behaviour.**

- Per channel, an **exchange** is a run of speech with no silence longer
  than the exchange gap (default 20 s). When an exchange ends, its voices
  are forgotten.
- Within an exchange, each voice gets the next letter in order of first
  appearance: A, B, C… After Z, letters continue as AA, AB (unlikely but
  defined).
- Each final line gets one letter. A line whose speech changes voice
  partway is split at the change into two final lines with their own
  letters and session offsets.
- A short line ("Copy", under about 1 s of speech) gives a poor
  voiceprint. It is matched to the closest voice in the exchange if close
  enough by a looser threshold, otherwise marked unknown (no letter, shown
  as "·") rather than inventing a new voice.

**Cues come first (my call).** Voice analysis never delays automation.
When the engine finalises a line, rules run on the whole line at once,
exactly as today. The transcript display, the `.jsonl` record and reports
receive the line after voice analysis, with its letter and any split. So
the transcriber's final output has two stages: a recognised line (sent to
rules immediately) and its voice-annotated form (one or more lines, sent to
the timeline and writer). With voice changes off, the second stage is the
first unchanged and nothing waits. `wilco-bench` measures both delays:
recognition-to-rules (must match today's) and recognition-to-display.

**Where it runs.**

- A `VoiceTracker` per channel in `WilcoCore`/`WilcoTranscription`: given
  16 kHz audio for a span and the span's session offsets, it returns change
  points and a letter per piece. It holds the exchange's voices (a running
  mean print per letter) in memory only.
- The transcriber is the only reader of the ring, so it feeds the tracker.
  Utterance-based transcribers (Parakeet, Whisper) already hold each
  utterance's audio. Apple's streaming transcriber keeps a bounded history
  of recent 16 kHz audio (enough for the longest line, capped at ~30 s)
  keyed by session offset, and hands the span of each final line to the
  tracker. No allocation or locking moves onto the audio thread; this all
  happens in the transcriber's pump.
- **Splitting needs word timings.** Each engine gives them: Apple
  (`audioTimeRange` attribute on results), WhisperKit (word timestamps
  option), Parakeet (token timings). A transcriber emits final lines with
  optional per-word offsets; a shared splitter cuts at the word nearest
  each change point. An engine without timings for a line keeps the line
  whole and gives it the letter of its longest piece.
- The embedding model loads once per app and is shared by every channel,
  like the speech models. It downloads with an Install button in Settings
  (it's small) or on first use.

**Settings (per show, with defaults so older shows decode):**

- Voice changes on/off per channel (`ChannelConfig.detectsVoiceChanges`).
  Existing shows decode it as false; new channels default to true (the
  32-channel benchmark passed with it on).
- Show-level tuning: **voice difference threshold** and **exchange gap**,
  in Settings with a "Restore defaults" button. Shown as plain words with
  the number ("Stricter ←→ Looser") rather than raw cosine values alone.

**Display.**

- Transcript: a letter badge after the time, before the text. A letter
  that differs from the line above on the same channel starts a visibly
  new turn. Channel tint is unchanged.

  ```
   SM   19:42:03  A  Standby lighting cue 42 and sound cue 17
        19:42:03  B  Lighting standing by
        19:42:04  C  Sound standing by
        19:42:06  A  LX 42, sound 17, go
        19:42:09  D  Sorry, was that 42 or 43?
  ```

- Reports: the same letter in the HTML report's chat log and channel
  views; SRT/VTT cues prefix the text with the letter ("B: Lighting
  standing by"). A report of a session without letters looks as it does
  today.
- Automation: `{voice}` is reserved in templates and always empty for now:
  rules fire on the recognised line before voice analysis, so no letter is
  known when they run. Rules don't match on it in this project.

**Stored data.**

- `TranscriptSegment` gains `voice: String?` (the letter; absent when
  voice changes are off or unknown) and `exchange: Int?` (a per-channel
  counter, so a report can tell "A in exchange 3" from "A in exchange 4").
  Both optional; old `.jsonl` files decode unchanged, and the encoder omits
  them when nil so files from channels without the feature are
  byte-identical to today's. Update `docs/SPEC.md`.
- No voiceprints anywhere on disk.

**Measuring it.**

- `wilco-bench` scenarios gain multi-voice channels: consecutive calls on
  one channel in different `say` voices, some back-to-back with no pause
  (the merged-line case), some returning to an earlier voice.
- New report columns: missed voice changes, false voice changes, letter
  accuracy (does a returning voice get its old letter), and the CPU and
  delay cost with the feature on versus off.
- `--corpus` supports a marked-up transcript for real recordings (a
  speaker letter per line in `name.txt`), so real comms can be scored the
  same way.
- `say` voices are far more distinct than real people on a comms line;
  numbers from them are a best case and the defaults must be revisited on
  real audio.

## Order of work

1. Part 1 (Parakeet engine).
2. Part 2 (vocabulary), on top of Part 1. Parts 1 and 2 land together:
   Parakeet doesn't appear in the engine picker until vocabulary works, so
   it never silently ignores cue words and rule phrases. (My call.)
3. Part 3 (voice changes): the benchmark scoring and `VoiceTracker`
   first, measured at 32 channels, then the per-engine timings and
   splitting, then display and reports.

Each part ends with package tests, the CI app build, a `wilco-bench` run,
and a PROGRESS.md entry; "verified" only once the user has tried it in the
app.

## Left to the builder

- Exact FluidAudio calls for the embedding model (its `EmbeddingExtractor`
  takes a fixed 10 s window with activity masks; whether a lighter path
  exists for short spans), the window size and hop for voiceprints, and
  how change points are found from them (e.g. distance between
  neighbouring prints above the threshold, with a minimum turn length).
- The default threshold values, from benchmark runs.
- Whether a chosen language can be passed to Parakeet v3.
- Layout details of the letter badge and the Settings sections, following
  the existing views.
