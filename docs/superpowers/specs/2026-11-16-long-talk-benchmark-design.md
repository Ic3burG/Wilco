# Long-talk benchmark — design

2026-11-16. A small change to `wilco-bench`.

## Why

`UtteranceSegmenter` used to cut continuous talking mid-sentence and then
ignore what followed. The user found it by ear in the app; the benchmark
never saw it, because its `say` calls are short, clean and separated by
gaps. The benchmark should catch this class of bug before the user does.

## Goals

- A run of long, unbroken talking in room sound, on many channels, through
  the same path the app uses.
- A number that shows speech going missing, and a verdict that fails on it.
- It fails with the old segmenter rule and passes with the current one.

## Non-goals

- Changing the default sweep or `--conversation`. Their numbers must stay
  comparable with earlier runs.
- Fixing quiet mics (speech under the 0.005 absolute minimum).
- Real recordings. `--corpus` already covers those.

## Anti-goal

A mode that passes while speech is being dropped. Today a 15 s talk cut off
at 5 s still counts as answered (a final line starts inside it), and "keeps
up" ignores word errors.

## Approaches

1. **A separate `--long-talk` mode (chosen).** Alongside `--conversation`:
   its own clips, scenario and pass bar. Earlier results stay comparable.
2. Mix long talks into the default sweep. Rejected: every WER and delay
   figure would shift, and a lock-out on a few long talks would be diluted
   by hundreds of short calls.
3. Only more segmenter unit tests. Rejected: they exist already
   (`ContinuousSpeechSegmenterTests`); they don't cover engines, load or
   the end-to-end path.

## Design

- **Passages.** `ClipLibrary.passages`: about six written passages of
  10–25 s of unbroken talking, as someone explaining a problem on comms
  would speak. Rendered by `say` in the usual voices and cached like the
  short phrases. Keep sentence breaks few, so `say` doesn't insert pauses
  near the segmenter's 0.7 s.
- **Room sound.** The echo-and-hiss treatment from
  `ContinuousSpeechSegmenterTests` moves into `WilcoBench` as a public,
  seeded function (four echoes at 30/70/130/210 ms, gains
  0.5/0.35/0.25/0.15, hiss ±0.002, then a level). The test uses the shared
  one. Echo delays scale with the sample rate (the bench runs at 48 kHz).
- **Scenario.** `Scenario.generateLongTalks`: each channel plays passages
  with 3–8 s of quiet between them, seeded. Each channel has its own level
  between ×0.1 and ×0.3. About a third of talks drop to ×0.06 halfway
  through (loud, then quiet: the second lock-out case). Hiss runs for the
  whole track, not only under speech.
- **Measure: words lost.** Deleted words ÷ reference words for the run,
  from the existing channel-wide word alignment. New optional field on
  `RunResult`, so older report files still decode. Shown as a column in
  long-talk runs.
- **Verdict.** In long-talk runs "keeps up" also needs words lost ≤ 10%.
  (My call: Whisper base loses 1–2% on clean `say`; the bug lost 33–50%.)
  Final delay for a talk runs from its end to its last final line, as now.
  A talk longer than the 20 s cut gives several lines; that's expected.
- **Tool.** `--long-talk` flag, exclusive with `--conversation`; the
  report header says which mode ran. `BENCHMARK.md` gets a section.

## Tests

- Unit: the room function (length, determinism), `generateLongTalks`
  (seeded, gaps, levels, whole talks only), words lost, the verdict.
- Runner test with a test-double engine that drops the second half of each
  talk: the run must not "keep up".
- By hand, once: revert the segmenter rule locally, run
  `--long-talk`, confirm it fails; restore, confirm it passes. Record both
  in `docs/benchmarks/`.

## Left to the builder

Passage wording, exact share of loud-then-quiet talks, where the level
change is applied (per `ScheduledUtterance` or in `ChannelTrack`), column
layout.
