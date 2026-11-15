# Wilco transcription benchmark

**Decision:** `parakeet-v3-vocab` keeps up at 32 channels (2.6% WER, 0/266
missed, 0.76 s p95, no dropped audio), so the per-channel "Use vocabulary" switch
(Task 6) isn't needed. Boosting cost about 2% of one core and
0.3 s more start-up at 32 channels, and did not make WER worse: 38 word
errors against 46 without it (no deletions either way; the four
insertions without boosting went away). Both engines build one recognizer
per channel over one shared model store, as the app does. Run on
2026-11-15 on AC power with the Mac kept awake; an earlier run on
2026-11-13 was spoiled by the Mac going to sleep with the lid closed.

2026-11-15T21:42:18Z · Apple M1 Max, 10 cores, 64 GB · macOS Version 27.2.1 (Build 26B131) · speech: say (Samantha en_US, Daniel en_GB, Karen en_AU, Moira en_IE; 160 clips · Mac idle: 23% CPU

| Engine | Ch | WER | Missed | Final delay p50 / p95 / max | First words p50 | Backlog | Start | CPU (us) | CPU (Mac) | Memory | Dropped | Keeps up |
|---|---:|---:|---:|---|---:|---:|---:|---:|---:|---:|---:|:---:|
| parakeet-v3 | 1 | 0.0% | 0/8 | 0.77 / 0.90 / 0.90 s | 2.78 s | 0.00 s | 0.18 s | 3% | 22% | 111 MB | 0 | yes |
| parakeet-v3 | 8 | 1.3% | 0/60 | 0.69 / 0.75 / 0.78 s | 2.95 s | 0.00 s | 0.17 s | 11% | 25% | 145 MB | 0 | yes |
| parakeet-v3 | 16 | 2.1% | 0/128 | 0.68 / 0.76 / 0.82 s | 2.94 s | 0.00 s | 0.15 s | 22% | 25% | 171 MB | 0 | yes |
| parakeet-v3 | 32 | 3.1% | 0/266 | 0.67 / 0.75 / 0.79 s | 2.88 s | 0.00 s | 0.15 s | 40% | 24% | 213 MB | 0 | yes |
| parakeet-v3-vocab | 1 | 0.0% | 0/8 | 0.74 / 0.87 / 0.87 s | 2.81 s | 0.00 s | 0.43 s | 3% | 21% | 205 MB | 0 | yes |
| parakeet-v3-vocab | 8 | 0.8% | 0/60 | 0.71 / 0.88 / 1.07 s | 2.95 s | 0.00 s | 0.46 s | 13% | 24% | 195 MB | 0 | yes |
| parakeet-v3-vocab | 16 | 1.6% | 0/128 | 0.69 / 0.78 / 0.79 s | 2.90 s | 0.00 s | 0.44 s | 24% | 33% | 114 MB | 0 | yes |
| parakeet-v3-vocab | 32 | 2.6% | 0/266 | 0.68 / 0.76 / 0.88 s | 2.89 s | 0.00 s | 0.42 s | 42% | 33% | 137 MB | 0 | yes |

WER: word error rate over each channel's whole transcript. Final delay: end of a call to its final line. Backlog: how long after the audio stopped the last line arrived. CPU (us): cores this process used (100% = one core). CPU (Mac): share of all cores busy. Keeps up: no failures or dropped audio, ≤ 5% of calls missed, p95 delay and backlog ≤ 3 s.
