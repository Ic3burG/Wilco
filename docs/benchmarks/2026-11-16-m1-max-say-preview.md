# Wilco transcription benchmark: Parakeet live preview

**Result:** with live preview on ("Fast, then corrected"), Parakeet keeps up
at 32 channels, and final lines arrive within 0.1 s of the no-preview
engine. That is inside the 0.25 s allowed. Words now appear sooner: the
median time from the start of a call to its first words fell from about
3.1 s to 1.7–2.5 s at 32 channels, and to 0.7 s on one channel.

Pass bar (from the design): `parakeet-v3-preview` keeps up at 32 channels
with final p95 within 0.25 s of `parakeet-v3` at the same channel count.

2026-11-16, Apple M1 Max, 10 cores, 64 GB, macOS 27.2.1, `say` speech
(4 voices, 160 clips), seed 1. These runs were **not** under
`caffeinate`, unlike earlier baselines.

## Channel sweep

Run: `wilco-bench --engines parakeet-v3,parakeet-v3-preview --channels 1,8,16,32`
(`2026-11-16-m1-max-say-preview.json`)

| Engine | Ch | Final p50 / p95 | First words p50 | CPU (us) | Keeps up |
|---|---:|---|---:|---:|:---:|
| parakeet-v3 | 1 | 0.73 / 1.00 s | 2.90 s | 2% | yes |
| parakeet-v3-preview | 1 | 0.68 / 0.78 s | 0.73 s | 7% | yes |
| parakeet-v3 | 8 | 0.69 / 0.89 s | 2.95 s | 11% | yes |
| parakeet-v3-preview | 8 | 0.66 / 0.74 s | 0.76 s | 32% | yes |
| parakeet-v3 | 16 | 0.68 / 0.75 s | 2.95 s | 22% | yes |
| parakeet-v3-preview | 16 | 0.67 / 0.78 s | 1.21 s | 45% | yes |
| parakeet-v3 | 32 | 0.67 / 0.74 s | 2.88 s | 39% | yes |
| parakeet-v3-preview | 32 | 0.67 / 0.84 s | 1.68 s | 62% | yes |

The package tests were running during the first (1-channel `parakeet-v3`)
run, which may explain its 1.00 s p95.

## Conversation with voice changes, 32 channels

Run: `wilco-bench --conversation --engines <both, order alternating> --channels 32 --voice-threshold 0.5`,
three rounds (`2026-11-16-m1-max-say-preview-conversation-{1,2,3}.json`).

| Round | Engine | Final p95 | Display p95 | First words p50 | Keeps up |
|---|---|---:|---:|---:|:---:|
| 1 | parakeet-v3-voices | 0.76 s | 0.98 s | 3.10 s | yes |
| 1 | parakeet-v3-preview-voices | 0.73 s | 0.96 s | 2.22 s | yes |
| 2 | parakeet-v3-preview-voices | 0.72 s | 0.91 s | 2.23 s | yes |
| 2 | parakeet-v3-voices | 0.74 s | 0.91 s | 3.07 s | yes |
| 3 | parakeet-v3-voices | 0.82 s | 1.18 s | 3.13 s | yes |
| 3 | parakeet-v3-preview-voices | 0.78 s | 1.01 s | 2.46 s | yes |

Letters, missed and false voice changes were the same with and without
preview (53/134 missed, 2 false, 82% right).

## Stalls seen earlier the same day

Before these rounds, three runs failed with a stall: two of
`parakeet-v3-preview-voices` (final p95 3.31 s and 6.54 s) and one of
`parakeet-v3-voices` without preview (final p95 1.94 s, display p95 4.01 s).
Timing logs showed every Neural Engine call slowing down for 7–18 s at
once, Parakeet and the voice model alike. One final took 2.4 s at one call
per second, so it wasn't backlog. Outside the stall the same runs were
fast (finals about 0.1 s).

The cause wasn't confirmed. It happens without preview, so preview isn't
it. Candidates are macOS speech services sharing the Neural Engine
(`com.apple.siri.embeddedspeech` was seen at 40% CPU between runs) and
power management, since these runs weren't under `caffeinate`. In the
three rounds above, those services were busy for only 3 of 377 seconds,
and no final took longer than 0.32 s.

Planning a show around these numbers: a stall like this would hit any
engine that uses the Neural Engine, with or without preview. Quit other
speech features (dictation, Live Captions, Siri) on a show Mac.
