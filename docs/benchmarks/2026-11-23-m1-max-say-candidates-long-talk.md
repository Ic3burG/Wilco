# Wilco transcription benchmark

2026-11-23T08:11:45Z · Apple M1 Max, 10 cores, 64 GB · macOS Version 27.2.1 (Build 26B131) · speech: say (Samantha en_US, Daniel en_GB, Karen en_AU, Moira en_IE; 28 clips, long talks · Mac idle: 21% CPU

| Engine | Ch | WER | Words lost | Missed | Final delay p50 / p95 / max | Display p95 | First words p50 | Backlog | Start | CPU (us) | CPU (Mac) | Memory | Dropped | Keeps up |
|---|---:|---:|---:|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|:---:|
| parakeet-v3 | 8 | 0.5% | 0.0% | 0/40 | 0.64 / 0.83 / 0.92 s | 0.83 s | 16.26 s | 0.00 s | 0.19 s | 22% | 31% | 220 MB | 0 | yes |
| parakeet-v3 | 32 | 0.3% | 0.0% | 0/164 | 0.66 / 1.04 / 1.89 s | 1.04 s | 16.37 s | 0.00 s | 0.20 s | 80% | 40% | 242 MB | 0 | yes |
| parakeet-v3-preview | 8 | 0.5% | 0.0% | 0/40 | 0.63 / 0.80 / 0.87 s | 0.80 s | 1.17 s | 0.00 s | 0.20 s | 78% | 39% | 164 MB | 0 | yes |
| parakeet-v3-preview | 32 | 0.3% | 0.0% | 0/164 | 0.65 / 0.86 / 1.16 s | 0.86 s | 2.77 s | 0.00 s | 0.18 s | 160% | 48% | 182 MB | 0 | yes |
| parakeet-ultra | 8 | 0.7% | 0.0% | 0/40 | 0.66 / 0.79 / 0.86 s | 0.79 s | 16.34 s | 0.00 s | 0.20 s | 22% | 35% | 125 MB | 0 | yes |
| parakeet-ultra | 32 | 0.6% | 0.1% | 0/164 | 0.64 / 0.89 / 1.01 s | 0.89 s | 16.23 s | 0.00 s | 0.19 s | 80% | 37% | 146 MB | 0 | yes |
| parakeet-unified-1120 | 8 | 0.6% | 0.2% | 0/40 | 0.50 / 0.65 / 0.68 s | 0.65 s | 1.76 s | 0.00 s | 0.25 s | 31% | 32% | 266 MB | 0 | yes |
| parakeet-unified-1120 | 32 | 0.5% | 0.0% | 0/164 | 0.57 / 0.99 / 1.31 s | 0.99 s | 1.76 s | 0.00 s | 0.60 s | 81% | 36% | 632 MB | 0 | yes |

WER: word error rate over each channel's whole transcript. Missed: calls with no final line; "merged" turns (conversations only) have no line of their own but are answered by the previous turn's line in the same exchange, final only after they ended; that line's delay runs from the end of the last turn in it. Final delay: end of a call to its final line, when rules can act on it. Display: end of a call to its line on screen, after voice analysis. Backlog: how long after the audio stopped the last final line arrived. CPU (us): cores this process used (100% = one core). CPU (Mac): share of all cores busy. Keeps up: no failures or dropped audio, ≤ 5% of calls missed, p95 final delay and backlog ≤ 3 s; with voice changes on, also display p95 and display backlog ≤ 3 s.

Words lost: spoken words with nothing in the transcript where they belong, as a share of all words spoken. Each call here is a long stretch of unbroken talking over hiss, and some drop to a quiet voice halfway. Keeps up also needs words lost ≤ 10%.
