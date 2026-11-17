# Wilco transcription benchmark: long talks

**Result:** the new `--long-talk` run sees the segmenter bug the other runs
couldn't. With the old noise-floor rule put back, 62–64% of the words are
lost and the run fails, while "Missed" still reads 0/40. With the current
rule Parakeet loses nothing at 1, 8 or 32 channels. Whisper base doesn't
cope with 32 channels of long talking, though its numbers there can't be
trusted in detail.

2026-11-16, Apple M1 Max, 10 cores, 64 GB, macOS 27.2.1, on AC power under
`caffeinate -dims`. `say` speech: 7 passages of 13–17 s in 4 voices
(Samantha, Daniel, Karen, Moira), with room echo and hiss, 3–8 s apart,
seed 1, 120 s runs. Channels talk about 65% of the time. "Mac idle" read
18% before the run, so treat CPU (Mac) as noise.

## Current segmenter

Run: `wilco-bench --long-talk --duration 120 --engines parakeet-v3,whisper-base,apple-longform --channels 1,8,32`
(`2026-11-16-m1-max-say-long-talk.json`)

| Engine | Ch | WER | Words lost | Missed | Final p50 / p95 / max | CPU (us) | Dropped | Keeps up |
|---|---:|---:|---:|---:|---|---:|---:|:---:|
| parakeet-v3 | 1 | 1.9% | 0.0% | 0/5 | 0.67 / 0.78 / 0.78 s | 4% | 0 | yes |
| parakeet-v3 | 8 | 0.5% | 0.0% | 0/40 | 0.65 / 0.81 / 0.94 s | 23% | 0 | yes |
| parakeet-v3 | 32 | 0.3% | 0.0% | 0/164 | 0.65 / 0.86 / 1.10 s | 84% | 0 | yes |
| whisper-base | 1 | 3.8% | 0.0% | 0/5 | 1.00 / 1.06 / 1.06 s | 3% | 0 | yes |
| whisper-base | 8 | 5.7% | 3.5% | 0/40 | 0.90 / 1.14 / 1.37 s | 15% | 0 | yes |
| whisper-base | 32 | 6.5% | 4.6% | 47/164 | 4.79 / 14.15 / 23.43 s | 49% | 3866 | **no** |
| apple-longform | 1 | 3.2% | 0.6% | 0/5 | 0.44 / 0.81 / 0.81 s | 2% | 0 | yes |
| apple-longform | 8 | 2.0% | 0.3% | 0/40 | 0.27 / 1.05 / 6.41 s | 8% | 0 | yes |
| apple-longform | 32 | 1.9% | 0.2% | 0/164 | 0.46 / 1.10 / 6.36 s | 19% | 0 | yes |

- **Parakeet** keeps up at 32 channels with no words lost. It uses 84% of
  a core here against 37% on short calls at 30% talk time: there is more
  than twice the speech.
- **Whisper base fails at 32 channels, but that row doesn't add up.** 47
  talks count as missed, yet only 4.6% of the words are gone, and no line
  arrived after the audio stopped although delays read up to 23 s. Likely
  cause, from the code and not yet measured: each Whisper channel waits
  for the shared model before reading more audio. When that wait passes
  2 s the channel's buffer treats it as not listening, and audio it then
  discards isn't counted as dropped. The channel's clock falls behind, so
  its lines carry start times that are too early and get matched to the
  wrong talk or to none. So "something is wrong at 32 channels" holds
  (it keeps up at 8); the missed count and the delays in that row don't.
- **Whisper base loses 3.5% of words at 8 channels** with no dropped
  audio. The saved transcripts show where: twice it ends a talk at "…keep
  dropping..." and leaves out the rest. Parakeet gets the same talks whole
  from the same segmenter, so this is the Whisper model giving up on a
  line, not audio going missing. It is under the 10% bar.
- **Apple long-form** keeps up and loses almost nothing. It doesn't use
  the segmenter. Its slowest line was 6.4 s behind.
- Parakeet and Whisper show first words about 16 s after a talk starts:
  without live preview, nothing appears until the talk ends.

## After the run-end fix

The table above was measured before a fix to how a long-talk run ends: it
used to stop as soon as every talk had one line, which could cut off a
talk's later lines. Parakeet and Apple long-form were run again at 32
channels with the fix (`2026-11-16-m1-max-say-long-talk-rerun.json`), and
nothing moved beyond run-to-run noise:

| Engine | Ch | WER | Words lost | Missed | Final p50 / p95 / max | CPU (us) | Keeps up |
|---|---:|---:|---:|---:|---|---:|:---:|
| parakeet-v3 | 32 | 0.3% | 0.0% | 0/164 | 0.63 / 0.85 / 1.03 s | 84% | yes |
| apple-longform | 32 | 1.9% | 0.2% | 0/164 | 0.49 / 1.18 / 6.44 s | 18% | yes |

Whisper base and the old-rule run were not repeated.

## Old segmenter rule

The same run with `UtteranceSegmenter.swift` as it was before the
noise-floor fix (working tree only, then restored), 8 channels
(`2026-11-16-m1-max-say-long-talk-old-rule.json`):

| Engine | Ch | WER | Words lost | Missed | Final p50 / p95 | Keeps up |
|---|---:|---:|---:|---:|---|:---:|
| parakeet-v3 | 8 | 64.0% | 62.0% | 0/40 | −9.82 / −3.80 s | **no** |
| whisper-base | 8 | 65.4% | 64.5% | 0/40 | −9.67 / −3.82 s | **no** |

- Nearly two thirds of the words never reached the recogniser.
- "Missed" is 0/40: every talk got a line, which is why the short-call
  runs never showed the bug. Words lost is the number that shows it.
- The delays are negative because the last line arrived about 10 s
  before the talk ended; the rest of the talk was ignored.
