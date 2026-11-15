# Wilco transcription benchmark

**Decision:** voice changes stay **off by default** for new channels.
`parakeet-v3-voices` and `whisper-base-voices` keep up at 32 channels with
both cues and display, but `apple-longform-voices` doesn't (final p95
5.76 s). That failure belongs to Apple long-form itself: in this
conversation scenario plain `apple-longform` also fails at 32 (final p95
5.99 s). Voice analysis adds little: the display trails the final line by
0.04–0.18 s at p95 and costs 7–8% of one core at 32 channels. With Whisper
it also pushed the final p95 from 1.07 s to 1.87 s, probably because the
voice model and Whisper share the GPU. The threshold stays at **0.5**.

Run: `wilco-bench --conversation --engines parakeet-v3,parakeet-v3-voices,apple-longform,apple-longform-voices,whisper-base,whisper-base-voices --channels 1,8,16,32 --voice-threshold 0.5`
(60 s runs, seed 1).

Threshold sweep, `parakeet-v3-voices` × 8 channels, 180 s (122 calls, 85
voice changes, 38 of them merged turns, 35 returning turns):

| Threshold | Changes missed | False changes | Letters right |
|---:|---:|---:|---:|
| 0.4 | 48/85 | 0 | 27/35 (77%) |
| 0.5 | 53/85 | 0 | 33/35 (94%) |
| 0.6 | 56/85 | 0 | 34/35 (97%) |

A lower threshold finds more changes but gives a returning voice a new
letter more often. Going from 0.5 to 0.6 gains one letter and misses three
more changes. Real people on comms sound more alike than `say` voices, so
the threshold should not go up on this evidence. Revisit it on a real
corpus.

Reading the voice table: a line keeps one letter for now, so every pair of
turns the segmenter merged into one line (gaps under about 0.5 s) counts as
a missed change. At 32 channels that's 63 of Parakeet's 81 missed changes
(58 of Whisper's 82). Splitting lines mid-utterance should take those away;
this run is the baseline for that. Apple long-form cuts its own lines (only
6 merged), so it misses fewer changes (30/134), but its shorter pieces get
no letter more often (15/205). `say` voices are far more distinct than real
people, so treat these numbers as a best case.

2026-11-15T23:01:09Z · Apple M1 Max, 10 cores, 64 GB · macOS Version 27.2.1 (Build 26B131) · speech: say (Samantha en_US, Daniel en_GB, Karen en_AU, Moira en_IE; 160 clips · Mac idle: 25% CPU

| Engine | Ch | WER | Missed | Final delay p50 / p95 / max | Display p95 | First words p50 | Backlog | Start | CPU (us) | CPU (Mac) | Memory | Dropped | Keeps up |
|---|---:|---:|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|:---:|
| parakeet-v3 | 1 | 0.0% | 0/5 (1 merged) | 0.69 / 0.72 / 0.72 s | 0.72 s | 2.92 s | 0.00 s | 0.16 s | 2% | 17% | 109 MB | 0 | yes |
| parakeet-v3 | 8 | 3.8% | 0/49 (19 merged) | 0.64 / 0.73 / 0.74 s | 0.73 s | 3.21 s | 0.00 s | 0.16 s | 7% | 18% | 133 MB | 0 | yes |
| parakeet-v3 | 16 | 3.7% | 0/104 (36 merged) | 0.65 / 0.72 / 0.77 s | 0.72 s | 2.95 s | 0.00 s | 0.15 s | 13% | 23% | 137 MB | 0 | yes |
| parakeet-v3 | 32 | 3.1% | 0/192 (63 merged) | 0.64 / 0.72 / 0.81 s | 0.72 s | 3.02 s | 0.00 s | 0.16 s | 24% | 23% | 181 MB | 0 | yes |
| parakeet-v3-voices | 1 | 0.0% | 0/5 (1 merged) | 0.68 / 0.73 / 0.73 s | 0.79 s | 2.95 s | 0.00 s | 0.28 s | 2% | 19% | 580 MB | 0 | yes |
| parakeet-v3-voices | 8 | 3.8% | 0/49 (19 merged) | 0.63 / 0.75 / 0.79 s | 0.80 s | 3.23 s | 0.00 s | 0.24 s | 9% | 22% | 608 MB | 0 | yes |
| parakeet-v3-voices | 16 | 3.7% | 0/104 (36 merged) | 0.63 / 0.73 / 0.77 s | 0.82 s | 2.98 s | 0.00 s | 0.25 s | 18% | 21% | 613 MB | 0 | yes |
| parakeet-v3-voices | 32 | 3.1% | 0/192 (63 merged) | 0.64 / 0.72 / 0.76 s | 0.90 s | 3.01 s | 0.00 s | 0.25 s | 32% | 22% | 654 MB | 0 | yes |
| apple-longform | 1 | 2.9% | 0/5 | 1.23 / 1.54 / 1.54 s | 1.54 s | 1.52 s | 0.00 s | 0.01 s | 2% | 16% | 612 MB | 0 | yes |
| apple-longform | 8 | 7.1% | 0/49 (3 merged) | 0.95 / 1.55 / 1.72 s | 1.55 s | 1.38 s | 0.00 s | 0.02 s | 4% | 24% | 613 MB | 0 | yes |
| apple-longform | 16 | 8.1% | 0/104 (5 merged) | 0.97 / 1.64 / 1.84 s | 1.64 s | 1.39 s | 0.00 s | 0.03 s | 6% | 28% | 614 MB | 0 | yes |
| apple-longform | 32 | 6.4% | 1/192 (6 merged) | 1.52 / 5.99 / 7.50 s | 5.99 s | 2.52 s | 0.00 s | 0.05 s | 9% | 33% | 621 MB | 0 | **no** |
| apple-longform-voices | 1 | 2.9% | 0/5 | 1.19 / 1.48 / 1.48 s | 1.54 s | 1.46 s | 0.00 s | 0.11 s | 2% | 22% | 595 MB | 0 | yes |
| apple-longform-voices | 8 | 7.1% | 0/49 (3 merged) | 0.95 / 1.58 / 1.77 s | 1.62 s | 1.40 s | 0.00 s | 0.11 s | 6% | 26% | 560 MB | 0 | yes |
| apple-longform-voices | 16 | 7.9% | 0/104 (4 merged) | 0.95 / 1.60 / 1.85 s | 1.65 s | 1.33 s | 0.00 s | 0.10 s | 10% | 29% | 563 MB | 0 | yes |
| apple-longform-voices | 32 | 6.3% | 1/192 (6 merged) | 1.65 / 5.76 / 6.75 s | 5.80 s | 2.73 s | 0.00 s | 0.14 s | 17% | 34% | 613 MB | 0 | **no** |
| whisper-base | 1 | 0.0% | 0/5 (1 merged) | 0.72 / 0.83 / 0.83 s | 0.83 s | 2.95 s | 0.00 s | 0.65 s | 3% | 20% | 590 MB | 0 | yes |
| whisper-base | 8 | 12.8% | 4/49 (16 merged) | 0.72 / 0.90 / 1.17 s | 0.90 s | 3.32 s | 0.00 s | 0.63 s | 8% | 19% | 213 MB | 0 | **no** |
| whisper-base | 16 | 11.0% | 4/104 (33 merged) | 0.72 / 0.86 / 1.09 s | 0.86 s | 3.02 s | 0.00 s | 0.64 s | 14% | 18% | 233 MB | 0 | yes |
| whisper-base | 32 | 7.8% | 0/192 (63 merged) | 0.73 / 1.07 / 1.73 s | 1.07 s | 3.08 s | 0.00 s | 0.63 s | 21% | 22% | 293 MB | 0 | yes |
| whisper-base-voices | 1 | 0.0% | 0/5 (1 merged) | 0.76 / 0.81 / 0.81 s | 0.86 s | 2.97 s | 0.00 s | 0.73 s | 3% | 31% | 610 MB | 0 | yes |
| whisper-base-voices | 8 | 15.8% | 4/49 (17 merged) | 0.69 / 0.85 / 0.85 s | 0.93 s | 3.29 s | 0.00 s | 0.75 s | 9% | 19% | 643 MB | 0 | **no** |
| whisper-base-voices | 16 | 11.0% | 4/104 (33 merged) | 0.71 / 0.87 / 1.08 s | 0.96 s | 3.03 s | 0.00 s | 0.77 s | 17% | 23% | 660 MB | 0 | yes |
| whisper-base-voices | 32 | 10.4% | 8/192 (58 merged) | 0.76 / 1.87 / 3.05 s | 2.04 s | 3.25 s | 0.00 s | 0.75 s | 29% | 22% | 767 MB | 0 | yes |

WER: word error rate over each channel's whole transcript. Missed: calls with no final line; "merged" calls followed the previous one too closely to be cut apart and are answered by its line, whose delay then runs from the end of the last call in it. Final delay: end of a call to its final line, when rules can act on it. Display: end of a call to its line on screen, after voice analysis. Backlog: how long after the audio stopped the last final line arrived. CPU (us): cores this process used (100% = one core). CPU (Mac): share of all cores busy. Keeps up: no failures or dropped audio, ≤ 5% of calls missed, p95 final delay and backlog ≤ 3 s; with voice changes on, also display p95 and display backlog ≤ 3 s.

## Voice changes

| Engine | Ch | Changes missed | False changes | Letters right | No letter | Not annotated | Merged calls | Final p95 | Display p50 / p95 | Display backlog | CPU added | Threshold | Keeps up (cues / display) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---|---:|---:|---:|:---:|
| parakeet-v3-voices | 1 | 1/3 | 0 | 100% | 0/4 | 0 | 1 | 0.73 s | 0.72 / 0.79 s | 0.00 s | +1% | 0.50 | yes / yes |
| parakeet-v3-voices | 8 | 27/34 | 0 | 93% | 0/30 | 0 | 19 | 0.75 s | 0.69 / 0.80 s | 0.00 s | +2% | 0.50 | yes / yes |
| parakeet-v3-voices | 16 | 46/74 | 0 | 83% | 0/68 | 0 | 36 | 0.73 s | 0.70 / 0.82 s | 0.00 s | +5% | 0.50 | yes / yes |
| parakeet-v3-voices | 32 | 81/134 | 0 | 80% | 0/129 | 0 | 63 | 0.72 s | 0.71 / 0.90 s | 0.00 s | +7% | 0.50 | yes / yes |
| apple-longform-voices | 1 | 0/3 | 0 | 100% | 0/5 | 0 | 0 | 1.48 s | 1.23 / 1.54 s | 0.00 s | +0% | 0.50 | yes / yes |
| apple-longform-voices | 8 | 12/34 | 0 | 86% | 7/52 | 0 | 3 | 1.58 s | 0.99 / 1.62 s | 0.00 s | +2% | 0.50 | yes / yes |
| apple-longform-voices | 16 | 22/74 | 0 | 92% | 12/109 | 0 | 4 | 1.60 s | 0.99 / 1.65 s | 0.00 s | +4% | 0.50 | yes / yes |
| apple-longform-voices | 32 | 30/134 | 3 | 87% | 15/205 | 0 | 6 | 5.76 s | 1.76 / 5.80 s | 0.00 s | +7% | 0.50 | **no** / **no** |
| whisper-base-voices | 1 | 1/3 | 0 | 100% | 0/4 | 0 | 1 | 0.81 s | 0.81 / 0.86 s | 0.00 s | +0% | 0.50 | yes / yes |
| whisper-base-voices | 8 | 28/34 | 0 | 92% | 0/28 | 0 | 17 | 0.85 s | 0.73 / 0.93 s | 0.00 s | +1% | 0.50 | **no** / yes |
| whisper-base-voices | 16 | 46/74 | 0 | 81% | 0/67 | 0 | 33 | 0.87 s | 0.77 / 0.96 s | 0.00 s | +3% | 0.50 | yes / yes |
| whisper-base-voices | 32 | 82/134 | 0 | 80% | 0/126 | 0 | 58 | 1.87 s | 0.85 / 2.04 s | 0.00 s | +8% | 0.50 | yes / yes |

Changes missed: turn boundaries where the voice changes (within an exchange) with no change of letter within ±0.5 s. False: changes of letter with no change of voice within ±0.5 s. Two turns the segmenter merged into one line count as a missed change, since a line keeps one letter for now. Letters right: turns by a voice already heard in the exchange shown with its earlier letter. No letter: annotated lines without a letter (short or quiet lines, no voice model, or the channel's voice queue was full; these can't be told apart from outside). Not annotated: recognised lines whose annotation never arrived; each counts in the display delay at the moment the run stopped watching, a lower bound. Merged calls: turns that share an earlier turn's line. Display backlog: how long after the audio stopped the last line reached the screen. CPU added: this process's cores over the same engine without voice changes at the same channel count. Keeps up: cues / display, as above.
