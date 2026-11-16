# Wilco transcription benchmark: splitting lines where the voice changes

**Result:** with word timings, a line whose voice changes partway is now
split between words into lines with their own letters. At 32 channels,
missed voice changes fell from 81 to 53 of 134 on Parakeet and from 81 to
51 on Whisper, with 2 and 0 false changes. Apple long-form stayed at 30
because it already ends most lines where the voice changes. All three
`-voices` engines still keep up at 32 channels.

Run: `wilco-bench --conversation --engines parakeet-v3-voices,apple-longform-voices,whisper-base-voices --channels 32 --voice-threshold 0.5`
(60 s, seed 1, `caffeinate -dims`, AC power). Baseline: the 32-channel
rows of `2026-11-15-m1-max-say-voices.md`.

| Engine | Changes missed | False changes | Letters right | Final p95 | Display p95 | Keeps up |
|---|---:|---:|---:|---:|---:|:---:|
| parakeet-v3-voices, before | 81/134 | 0 | 80% | 0.73 s | 0.89 s | yes |
| parakeet-v3-voices, after | 53/134 | 2 | 82% | 0.76 s | 0.95 s | yes |
| apple-longform-voices, before | 30/134 | 3 | 87% | 1.92 s | 2.03 s | yes |
| apple-longform-voices, after | 30/134 | 3 | 87% | 1.73 s | 1.88 s | yes |
| whisper-base-voices, before | 81/134 | 0 | 79% | 2.01 s | 2.27 s | yes |
| whisper-base-voices, after | 51/134 | 0 | 82% | 2.39 s | 2.52 s | yes |

Notes:

- The first run of this change cut lines most of a word early, which gave
  25 false changes on Parakeet (missed 76). The tracker put each change at
  the start of the first voiceprint window that differed. Those windows
  are 1.5 s long, so that point is about 0.75 s before the change. A
  second try used the middle of that window (52 missed, 1 false, but a
  word late in the gated Parakeet test). The final rule, above, puts the
  change halfway between the middles of the last old and first new
  windows, a little early, so the cut falls in the pause before the new
  speaker.
- One run had Apple and Whisper miss the bar (final p95 4.3 s and 3.1 s)
  while Time Machine was backing up (Mac idle 46% CPU). Its voice scores
  matched the clean runs. The run above had Mac idle 24%.
- Whisper now asks for word timestamps when voice changes are on. Its final
  p95 at 32 channels was 2.37–2.46 s in three clean runs, against 2.01 s
  before. That leaves less room under the 3 s bar.
- Parakeet gave 157 lines against 129 before: 28 split pieces.
- Most of the remaining misses are turns the tracker doesn't find at all:
  neighbouring windows that don't differ by more than the threshold, or a
  change that would leave a piece under 0.8 s.

The tables below are the run's own report, rendered by `BenchReport`.

2026-11-16T06:53:30Z · Apple M1 Max, 10 cores, 64 GB · macOS Version 27.2.1 (Build 26B131) · speech: say (Samantha en_US, Daniel en_GB, Karen en_AU, Moira en_IE; 160 clips · Mac idle: 24% CPU

| Engine | Ch | WER | Missed | Final delay p50 / p95 / max | Display p95 | First words p50 | Backlog | Start | CPU (us) | CPU (Mac) | Memory | Dropped | Keeps up |
|---|---:|---:|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|:---:|
| parakeet-v3-voices | 32 | 3.1% | 0/192 (63 merged) | 0.65 / 0.76 / 0.79 s | 0.95 s | 3.12 s | 0.00 s | 0.33 s | 35% | 21% | 674 MB | 0 | yes |
| apple-longform-voices | 32 | 6.4% | 1/192 (6 merged) | 1.10 / 1.73 / 6.16 s | 1.88 s | 1.41 s | 0.00 s | 0.20 s | 20% | 32% | 713 MB | 0 | yes |
| whisper-base-voices | 32 | 6.7% | 0/192 (63 merged) | 0.84 / 2.39 / 4.61 s | 2.52 s | 3.52 s | 0.00 s | 0.89 s | 36% | 21% | 879 MB | 0 | yes |

WER: word error rate over each channel's whole transcript. Missed: calls with no final line; "merged" turns (conversations only) have no line of their own but are answered by the previous turn's line in the same exchange, final only after they ended; that line's delay runs from the end of the last turn in it. Final delay: end of a call to its final line, when rules can act on it. Display: end of a call to its line on screen, after voice analysis. Backlog: how long after the audio stopped the last final line arrived. CPU (us): cores this process used (100% = one core). CPU (Mac): share of all cores busy. Keeps up: no failures or dropped audio, ≤ 5% of calls missed, p95 final delay and backlog ≤ 3 s; with voice changes on, also display p95 and display backlog ≤ 3 s.

## Voice changes

| Engine | Ch | Changes missed | False changes | Letters right | No letter | Not annotated | Merged calls | Final p95 | Display p50 / p95 | Display backlog | CPU added | Threshold | Keeps up (cues / display) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---|---:|---:|---:|:---:|
| parakeet-v3-voices | 32 | 53/134 | 2 | 82% | 0/157 | 0 | 63 | 0.76 s | 0.74 / 0.95 s | 0.00 s | – | 0.50 | yes / yes |
| apple-longform-voices | 32 | 30/134 | 3 | 87% | 15/204 | 0 | 6 | 1.73 s | 1.14 / 1.88 s | 0.00 s | – | 0.50 | yes / yes |
| whisper-base-voices | 32 | 51/134 | 0 | 82% | 0/157 | 0 | 63 | 2.39 s | 0.91 / 2.52 s | 0.00 s | – | 0.50 | yes / yes |

Changes missed: turn boundaries where the voice changes (within an exchange) with no change of letter within ±0.5 s. False: changes of letter with no change of voice within ±0.5 s. Two turns the segmenter merged into one line count as a missed change unless the line was split there. Letters right: turns by a voice already heard in the exchange shown with its earlier letter. No letter: annotated lines without a letter (short or quiet lines, no voice model, or the channel's voice queue was full; these can't be told apart from outside). Not annotated: recognised lines whose annotation never arrived; each counts in the display delay at the moment the run stopped watching, a lower bound. Merged calls: turns that share an earlier turn's line. Display backlog: how long after the audio stopped the last line reached the screen. CPU added: this process's cores over the same engine without voice changes at the same channel count. Keeps up: cues / display, as above.
