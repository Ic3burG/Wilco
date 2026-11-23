# Neural Engine candidates vs Parakeet v3 (2026-11-23)

M1 Max, `say` speech, 60 s runs, 30% talk time. The full sweep (seed 1) is
below. Seeds 2 and 3 (32 channels, the five closest engines) are in the
`-seed2` / `-seed3` JSON files; the long-talk run is in
[`2026-11-23-m1-max-say-candidates-long-talk.md`](2026-11-23-m1-max-say-candidates-long-talk.md).

## Verdict

Keep Parakeet v3. No candidate is more accurate on this test, and the
streaming ones don't show words sooner than v3's live preview.

| Engine (32 channels) | WER seed 1 / 2 / 3 | Mean | Notes |
|---|---|---:|---|
| parakeet-v3 | 3.1 / 3.6 / 5.1% | 3.9% | Best or tied on every seed |
| parakeet-ultra | 4.1 / 4.4 / 5.2% | 4.6% | Same speed and memory as v3 |
| parakeet-unified-1120 | 5.1 / 3.7 / 8.2% | 5.7% | Streaming; first words 1.8 s |
| parakeet-unified-offline | 5.1 / 4.0 / 8.5% | 5.9% | |
| bark-3-clean | 5.4 / 7.2 / 7.9% | 6.8% | |
| phonon-2 | 12.1% | | Seed 1 only; first load took 172 s |
| parakeet-eou-320 | 13.2% | | 11 of 266 calls missed |
| nemotron-1120 | fails at 16 | | A full model per channel: 24 GB, dropped audio |

The one advantage seen: on long talks at 32 channels, Parakeet Unified
streaming showed first words in 1.8 s using 81% of a core, where v3 with
preview took 2.8 s at 160%. Preview re-reads the whole utterance each
time; streaming only reads the new audio. Worth revisiting if preview's
CPU becomes a problem.

All of this is `say` speech. A `--corpus` run with real comms recordings
could change the order (Ultra's published gains are on harder audio).

## Seed 1, every candidate

# Wilco transcription benchmark

2026-11-23T06:26:41Z · Apple M1 Max, 10 cores, 64 GB · macOS Version 27.2.1 (Build 26B131) · speech: say (Samantha en_US, Daniel en_GB, Karen en_AU, Moira en_IE; 160 clips · Mac idle: 29% CPU

| Engine | Ch | WER | Missed | Final delay p50 / p95 / max | Display p95 | First words p50 | Backlog | Start | CPU (us) | CPU (Mac) | Memory | Dropped | Keeps up |
|---|---:|---:|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|:---:|
| parakeet-v3 | 1 | 0.0% | 0/8 | 0.70 / 0.95 / 0.95 s | 0.95 s | 2.85 s | 0.00 s | 0.24 s | 2% | 22% | 115 MB | 0 | yes |
| parakeet-v3 | 8 | 1.3% | 0/60 | 0.69 / 0.75 / 0.78 s | 0.75 s | 2.99 s | 0.00 s | 0.18 s | 11% | 24% | 127 MB | 0 | yes |
| parakeet-v3 | 16 | 2.1% | 0/128 | 0.69 / 0.77 / 0.80 s | 0.77 s | 2.98 s | 0.00 s | 0.15 s | 23% | 27% | 141 MB | 0 | yes |
| parakeet-v3 | 32 | 3.1% | 0/266 | 0.69 / 0.78 / 1.16 s | 0.78 s | 2.95 s | 0.00 s | 0.15 s | 38% | 38% | 207 MB | 0 | yes |
| parakeet-ultra | 1 | 2.2% | 0/8 | 0.72 / 0.93 / 0.93 s | 0.93 s | 2.81 s | 0.00 s | 0.26 s | 2% | 28% | 156 MB | 0 | yes |
| parakeet-ultra | 8 | 1.3% | 0/60 | 0.67 / 0.73 / 0.73 s | 0.73 s | 2.93 s | 0.00 s | 0.18 s | 10% | 30% | 101 MB | 0 | yes |
| parakeet-ultra | 16 | 3.5% | 0/128 | 0.68 / 0.75 / 0.78 s | 0.75 s | 2.93 s | 0.00 s | 0.15 s | 19% | 29% | 103 MB | 0 | yes |
| parakeet-ultra | 32 | 4.1% | 0/266 | 0.67 / 0.74 / 0.76 s | 0.74 s | 2.90 s | 0.00 s | 0.15 s | 34% | 37% | 108 MB | 0 | yes |
| phonon-2 | 1 | 0.0% | 0/8 | 0.72 / 0.92 / 0.92 s | 0.92 s | 2.80 s | 0.00 s | 171.80 s | 3% | 38% | 107 MB | 0 | yes |
| phonon-2 | 8 | 10.8% | 0/60 | 0.69 / 0.75 / 0.87 s | 0.75 s | 2.98 s | 0.00 s | 0.93 s | 15% | 26% | 100 MB | 0 | yes |
| phonon-2 | 16 | 14.2% | 0/128 | 0.67 / 0.74 / 0.79 s | 0.74 s | 2.98 s | 0.00 s | 0.91 s | 25% | 34% | 104 MB | 0 | yes |
| phonon-2 | 32 | 12.1% | 0/266 | 0.66 / 0.73 / 1.14 s | 0.73 s | 2.89 s | 0.00 s | 0.90 s | 43% | 33% | 105 MB | 0 | yes |
| bark-3-clean | 1 | 2.2% | 0/8 | 0.75 / 0.93 / 0.93 s | 0.93 s | 2.80 s | 0.00 s | 0.19 s | 3% | 28% | 94 MB | 0 | yes |
| bark-3-clean | 8 | 3.7% | 0/60 | 0.71 / 0.78 / 0.80 s | 0.78 s | 3.01 s | 0.00 s | 0.20 s | 12% | 33% | 103 MB | 0 | yes |
| bark-3-clean | 16 | 5.6% | 0/128 | 0.70 / 0.77 / 0.89 s | 0.77 s | 2.96 s | 0.00 s | 0.18 s | 23% | 35% | 105 MB | 0 | yes |
| bark-3-clean | 32 | 5.4% | 0/266 | 0.69 / 0.77 / 0.82 s | 0.77 s | 2.92 s | 0.00 s | 0.18 s | 39% | 35% | 111 MB | 0 | yes |
| parakeet-unified-offline | 1 | 4.3% | 0/8 | 0.78 / 0.88 / 0.88 s | 0.88 s | 2.83 s | 0.00 s | 0.17 s | 2% | 30% | 116 MB | 0 | yes |
| parakeet-unified-offline | 8 | 3.2% | 0/60 | 0.73 / 0.78 / 0.79 s | 0.78 s | 3.00 s | 0.00 s | 0.17 s | 11% | 36% | 148 MB | 0 | yes |
| parakeet-unified-offline | 16 | 4.7% | 0/128 | 0.70 / 0.78 / 0.81 s | 0.78 s | 2.96 s | 0.00 s | 0.15 s | 17% | 42% | 179 MB | 0 | yes |
| parakeet-unified-offline | 32 | 5.1% | 0/266 | 0.71 / 0.86 / 1.04 s | 0.86 s | 2.97 s | 0.00 s | 0.15 s | 29% | 69% | 210 MB | 0 | yes |
| nemotron-1120 | 1 | 6.5% | 0/8 | 0.87 / 1.19 / 1.19 s | 1.19 s | 1.44 s | 0.00 s | 23.98 s | 24% | 43% | 1951 MB | 0 | yes |
| nemotron-1120 | 8 | 7.1% | 0/60 | 1.06 / 2.50 / 2.75 s | 2.50 s | 1.40 s | 0.00 s | 88.80 s | 118% | 49% | 11869 MB | 0 | yes |
| nemotron-1120 | 16 | 19.5% | 40/128 | 15.64 / 29.71 / 34.37 s | 29.71 s | 17.64 s | 16.75 s | 164.75 s | 320% | 60% | 24565 MB | 6456 | **no** |
| parakeet-unified-1120 | 1 | 4.3% | 0/8 | 0.78 / 0.83 / 0.83 s | 0.83 s | 1.79 s | 0.00 s | 0.25 s | 4% | 32% | 5597 MB | 0 | yes |
| parakeet-unified-1120 | 8 | 3.4% | 0/60 | 0.72 / 0.93 / 1.48 s | 0.93 s | 1.79 s | 0.00 s | 0.21 s | 22% | 24% | 835 MB | 0 | yes |
| parakeet-unified-1120 | 16 | 5.1% | 0/128 | 0.69 / 0.77 / 0.79 s | 0.77 s | 1.76 s | 0.00 s | 0.33 s | 31% | 34% | 972 MB | 0 | yes |
| parakeet-unified-1120 | 32 | 5.1% | 0/266 | 0.71 / 1.54 / 2.57 s | 1.54 s | 1.76 s | 0.00 s | 0.83 s | 53% | 45% | 1250 MB | 0 | yes |
| parakeet-eou-320 | 1 | 6.5% | 0/8 | 0.66 / 0.70 / 0.70 s | 0.70 s | 1.23 s | 0.00 s | 0.43 s | 7% | 39% | 853 MB | 0 | yes |
| parakeet-eou-320 | 8 | 10.8% | 0/60 | 0.65 / 0.70 / 0.72 s | 0.70 s | 1.21 s | 0.00 s | 0.17 s | 33% | 37% | 1111 MB | 0 | yes |
| parakeet-eou-320 | 16 | 12.0% | 4/128 | 0.64 / 0.71 / 0.73 s | 0.71 s | 1.24 s | 0.00 s | 0.28 s | 60% | 54% | 1400 MB | 0 | yes |
| parakeet-eou-320 | 32 | 13.2% | 11/266 | 0.66 / 0.77 / 1.16 s | 0.77 s | 1.23 s | 0.00 s | 0.43 s | 113% | 48% | 1951 MB | 0 | yes |

WER: word error rate over each channel's whole transcript. Missed: calls with no final line; "merged" turns (conversations only) have no line of their own but are answered by the previous turn's line in the same exchange, final only after they ended; that line's delay runs from the end of the last turn in it. Final delay: end of a call to its final line, when rules can act on it. Display: end of a call to its line on screen, after voice analysis. Backlog: how long after the audio stopped the last final line arrived. CPU (us): cores this process used (100% = one core). CPU (Mac): share of all cores busy. Keeps up: no failures or dropped audio, ≤ 5% of calls missed, p95 final delay and backlog ≤ 3 s; with voice changes on, also display p95 and display backlog ≤ 3 s.
