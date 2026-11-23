# Session diagnostics cost, Parakeet v3, 1 / 16 / 32 channels

2026-11-23 · Apple M1 Max, 10 cores, 64 GB · macOS 27.2.1 · speech: `say`, 4 voices, 30% talk time · seed 1 · 120 s runs

Command (once without and once with `--diagnostics`):

```sh
swift run -c release wilco-bench --engines parakeet-v3 --channels 1,16,32 --duration 120 [--diagnostics]
```

With `--diagnostics` every channel runs the per-minute meter in its read loop and one shared sound classifier takes a 3 s clip per channel per minute (about two rows per channel in a 120 s run). The recorder writes to a temporary file that is deleted after the run. The two runs were made back to back, not at the same time. The Mac was not idle for either: 41% of all cores busy before the run without diagnostics, 25% before the run with.

## Without --diagnostics

| Engine | Ch | WER | Missed | Final delay p50 / p95 / max | Display p95 | First words p50 | Backlog | Start | CPU (us) | CPU (Mac) | Memory | Dropped | Keeps up |
|---|---:|---:|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|:---:|
| parakeet-v3 | 1 | 3.2% | 0/18 | 0.71 / 0.81 / 0.81 s | 0.81 s | 2.66 s | 0.00 s | 0.24 s | 2% | 42% | 110 MB | 0 | yes |
| parakeet-v3 | 16 | 2.6% | 0/268 | 0.68 / 0.75 / 0.82 s | 0.75 s | 2.92 s | 0.00 s | 0.19 s | 20% | 33% | 159 MB | 0 | yes |
| parakeet-v3 | 32 | 2.9% | 0/537 | 0.68 / 0.76 / 1.01 s | 0.76 s | 2.90 s | 0.00 s | 0.16 s | 38% | 36% | 210 MB | 0 | yes |

## With --diagnostics

| Engine | Ch | WER | Missed | Final delay p50 / p95 / max | Display p95 | First words p50 | Backlog | Start | CPU (us) | CPU (Mac) | Memory | Dropped | Clips dropped | Keeps up |
|---|---:|---:|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|:---:|
| parakeet-v3 | 1 | 3.2% | 0/18 | 0.75 / 0.83 / 0.83 s | 0.83 s | 2.73 s | 0.00 s | 0.21 s | 3% | 27% | 160 MB | 0 | 0 | yes |
| parakeet-v3 | 16 | 2.6% | 0/268 | 0.69 / 0.76 / 0.82 s | 0.76 s | 2.91 s | 0.00 s | 0.16 s | 20% | 45% | 232 MB | 0 | 0 | yes |
| parakeet-v3 | 32 | 2.9% | 0/537 | 0.66 / 0.73 / 0.79 s | 0.73 s | 2.88 s | 0.00 s | 0.17 s | 35% | 35% | 289 MB | 0 | 0 | yes |

## Reading it

- Keeps up at every count, with and without. At 32 channels p95 final delay is 0.76 s without and 0.73 s with; no frames dropped; no calls missed; WER unchanged (2.9%).
- CPU (us), the cores this process used: 38% without and 35% with at 32 channels, 20% and 20% at 16. The difference is inside run-to-run noise (the background load differed between the runs); the meter and classifier did not add a measurable amount.
- Peak memory rises by about 50 to 80 MB with diagnostics (the sound classifier's model), 289 MB against 210 MB at 32 channels.
- Clips dropped is 0 at every count.
- Short runs: a minute closes by wall clock and a clip is taken only from a minute with at least 3 s of sound, so a 120 s run exercises the clip path about twice per channel. A longer run would load the classifier more times, not harder: the queue takes one clip at a time and a channel adds one clip a minute.
