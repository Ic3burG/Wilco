# Wilco transcription benchmark: after the segmenter noise-floor fix

**Result:** the fix costs nothing on short calls. Every engine keeps up at
32 channels with no missed calls, and final delay and CPU match the
baseline from earlier the same day
(`2026-11-16-m1-max-say-preview.md`). The benchmark still has no long,
continuous talking, so it does not measure what the fix gains; the
segmenter tests do.

2026-11-16, Apple M1 Max, 10 cores, 64 GB, macOS 27.2.1, `say` speech
(4 voices, 160 clips), seed 1, under `caffeinate -i`. A debug build of
Wilco was open but idle (0% CPU), and the Mac was otherwise busy during
the conversation run ("Mac idle" read 99%), so treat CPU (Mac) as noise.

## Channel sweep

Run: `wilco-bench --engines parakeet-v3,parakeet-v3-preview,whisper-base --channels 1,8,16,32`
(`2026-11-16-m1-max-say-segmenter-fix.json`)

| Engine | Ch | WER | Missed | Final p50 / p95 | First words p50 | CPU (us) | Keeps up |
|---|---:|---:|---:|---|---:|---:|:---:|
| parakeet-v3 | 1 | 0.0% | 0/8 | 0.73 / 0.79 s | 2.70 s | 2% | yes |
| parakeet-v3 | 8 | 1.3% | 0/60 | 0.72 / 0.78 s | 3.00 s | 11% | yes |
| parakeet-v3 | 16 | 2.1% | 0/128 | 0.70 / 0.77 s | 2.97 s | 21% | yes |
| parakeet-v3 | 32 | 3.1% | 0/266 | 0.70 / 0.77 s | 2.92 s | 37% | yes |
| parakeet-v3-preview | 1 | 0.0% | 0/8 | 0.73 / 0.80 s | 0.75 s | 6% | yes |
| parakeet-v3-preview | 8 | 1.3% | 0/60 | 0.70 / 0.76 s | 0.77 s | 29% | yes |
| parakeet-v3-preview | 16 | 2.1% | 0/128 | 0.69 / 0.76 s | 1.20 s | 42% | yes |
| parakeet-v3-preview | 32 | 3.1% | 0/266 | 0.68 / 0.76 s | 1.56 s | 64% | yes |
| whisper-base | 1 | 0.0% | 0/8 | 0.82 / 1.90 s | 2.75 s | 3% | yes |
| whisper-base | 8 | 5.5% | 0/60 | 0.79 / 1.15 s | 3.12 s | 9% | yes |
| whisper-base | 16 | 7.2% | 0/128 | 0.80 / 1.61 s | 3.08 s | 17% | yes |
| whisper-base | 32 | 7.6% | 0/266 | 0.76 / 0.99 s | 2.98 s | 30% | yes |

Before the fix, Parakeet at 32 channels: final p95 0.74 s without preview
and 0.84 s with; CPU 39% and 62%.

## Conversation with voice changes, 32 channels

Run: `wilco-bench --conversation --engines parakeet-v3-voices,parakeet-v3-preview-voices --channels 32 --voice-threshold 0.5`,
one round (`2026-11-16-m1-max-say-segmenter-fix-conversation.json`).

| Engine | Missed | Merged | Final p95 | Display p95 | First words p50 | Changes missed | False changes | Keeps up |
|---|---:|---:|---:|---:|---:|---:|---:|:---:|
| parakeet-v3-voices | 0/192 | 74 | 0.76 s | 0.96 s | 3.25 s | 59/134 | 4 | yes |
| parakeet-v3-preview-voices | 0/192 | 74 | 0.78 s | 1.11 s | 2.03 s | 59/134 | 4 | yes |

Merged turns rose from 63 to 74 of 192. The likely reason, not confirmed:
the old floor rule counted the tail of a turn as silence, which stretched
some short gaps between turns past the 0.7 s pause. Those turns now stay
in one line, which the voice splitter then has to divide.
