# Parakeet live preview: design

2026-11-16. Status: proposed.

## Intent

On Parakeet channels, show the words in italics while someone is still
talking, as Apple channels do, then replace them with the accurate line at
the pause, as happens now. The final line, which rules fire on, must arrive
no later than it does today.

## Goals

- Volatile (italic) text on Parakeet channels while an utterance is in
  progress.
- The final line and its timing stay the same.
- Controlled by the existing per-channel **Latency** picker: "Fast, then
  corrected" turns previews on and "Single pass" turns them off. It stays
  disabled for Whisper.
- Still keeps up at 32 channels in `wilco-bench`.

## Non-goals

- Previews for Whisper.
- Sending previews anywhere other than the screen. Rules, OSC, MIDI, MOS,
  HTTP, peers and the session file still get only final lines, as with
  Apple's volatile text (`AppModel.swift` already drops non-final events).
- Vocabulary boosting on previews. Only the final line gets it.
- A new streaming model (FluidAudio's streaming managers use other models
  and run about 2 s behind).

## Anti-goals (a failure even if previews work)

- Final lines arriving later, which would make cues fire late.
- A preview showing up after its own final line, which would bring back
  stale italics.
- 32 Parakeet channels no longer keeping up.

## Approaches considered

1. **Previews inside the channel's existing loop.** While the segmenter is
   in an utterance, transcribe the audio so far every ~0.5 s and send it as
   volatile, skipping the preview if the shared model is busy. **Chosen.**
   One loop produces both previews and the final line, so their order is
   guaranteed, and a gate on the model keeps final lines first.
2. **A separate preview task per channel.** This could send a preview after
   its final line, so it would need extra ordering logic and gives nothing
   in return. Rejected.
3. **FluidAudio's streaming recogniser** (`StreamingUnifiedAsrManager`,
   EOU, Nemotron). These are different models from the TDT v3 we ship, keep
   state per stream (32 at a time) and run about 2 s behind, which is slower
   than our current 0.76 s p95 final line. Rejected; it would be a model
   change in its own right.

## Decisions (agreed)

- Option 1 (above).
- Reuse `ChannelConfig.latencyProfile`. Its stored default is
  `leadAndCorrect`, so **existing Parakeet channels get previews by
  default**. No change to the file format.

## Design

**Segmenter** (`UtteranceSegmenter`): add a read-only view of the
utterance in progress (its samples so far and its start offset), or nil
when not in speech. Nothing else about how it cuts changes.

**Recognizer protocol** (`UtteranceRecognizer`): add
`preview(_ samples: [Float]) async -> Recognition?`, with a default
implementation that returns nil. Recognizers that don't support previews,
such as the benchmark's Whisper ones, are unaffected.

**Priority gate** (in `ParakeetModelStore`, which every channel shares):
- A final `recognize` registers as waiting, then takes its turn on the
  model as it does today.
- A `preview` runs only if the model is idle and no final is waiting.
  Otherwise it returns nil at once and never queues.
- `ParakeetRecognizer.preview` uses the gate, skips the vocabulary
  booster, and pads clips under a second the same way `recognize` does.

**Transcriber** (`UtteranceChannelTranscriber`): a new init parameter,
`previewInterval: Duration?` (nil means off). On each pump pass, after
handing finished utterances to `transcribe`:
- If there is an utterance in progress, at least `previewInterval` has
  passed since the last preview attempt, and the utterance has at least
  ~0.5 s of audio, call `recognizer.preview` on it.
- If it returns non-empty text, send
  `TranscriptionEvent(isFinal: false, sessionOffset: utterance start)`.
- An empty or nil result sends nothing, and the italics already showing
  stay until the next preview or the final line.
- Final lines take the same path as now. Because the loop waits for each
  preview before cutting the next utterance, a preview can never arrive
  after its final line.

**Factory** (`ChannelTranscribers.make`): for Parakeet, pass
`previewInterval: .milliseconds(500)` when
`configuration.latencyProfile == .leadAndCorrect`, otherwise nil.
Changing the picker already restarts the channel's transcriber
(`TranscriptionController`).

**Inspector**: enable the Latency picker for Apple and Parakeet, and keep
it disabled for Whisper. Adjust the help text so it covers both engines,
for example: "Shows words as they are spoken, then replaces them with the
finished line. Uses more CPU per channel."

**Voice changes**: a `.recognized` line keeps its text as the channel's
volatile text until its annotation arrives. A preview of the *next*
utterance replaces that text on screen. The annotated pieces still settle
as segments, so nothing is lost; the earlier line just briefly gives way
to the new italics (about 1 s at worst). This is how Apple channels already
behave, so no change is planned.

**SPEC.md §6**: the `leadAndCorrect` note covers Parakeet: the same model
transcribes the utterance so far for the preview and the whole utterance
for the final line, with final lines first.

## Benchmark and acceptance

- Add a `wilco-bench` engine `parakeet-v3-preview` (previews on), next to
  `parakeet-v3` (off).
- Run both at 1, 8, 16 and 32 channels, plus `--conversation` with voice
  changes at 32.
- Pass: the preview engine "keeps up" at 32 channels, and its final p95
  is within 0.25 s of the no-preview run at the same channel count. Save
  the baseline in `docs/benchmarks/`.
- If it fails, the fallbacks in order are: a longer interval (1 s), then
  previews only on channels with fewer than N utterances in flight, then
  making the Parakeet default `single`. Each one comes back to the user
  first.

## Tests (Swift Testing)

- Segmenter: the in-progress view is nil in silence, grows during speech
  with the right start offset, and is nil again after a cut.
- Gate: a preview returns nil while a final is waiting or running; finals
  run in order; a preview runs when the model is idle.
- Transcriber, with a fake recognizer and a fake audio source: volatile
  events arrive during speech, the final arrives after them, and no
  volatile event for an utterance comes after its final; nothing is
  previewed when `previewInterval` is nil.
- Factory: Parakeet + `leadAndCorrect` turns previews on and `single`
  turns them off.
- Gated ASR test (`WILCO_ASR_TESTS`): real Parakeet previews of a
  `say` clip produce non-empty volatile text before the final line.

## Left to the builder

- Exact preview minimum (0.5 s) and whether to skip a preview when the
  utterance hasn't grown since the last one.
- How the gate is built inside the store (counters plus a continuation
  queue, or similar), as long as previews never wait.
- Whether the benchmark reports preview counts and skips, which would be
  useful but isn't required.
