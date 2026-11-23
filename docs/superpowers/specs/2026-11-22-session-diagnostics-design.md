# Session diagnostics: levels, dropouts and music (show review stage 2)

Status: draft 2026-11-22. The user chose to include music/singing detection
and approach A (meter where the engines read audio).

## Why

Stage 1 of the show review (`2026-11-22-show-review-design.md`) works from
the transcript alone, and two of the things the 2026-11-21 session showed
can't be judged from text:

- Three channels were nearly silent all show. The transcript can't say
  whether nobody talked, the level was too low to be heard, or the input
  was dead.
- The artist vocal mic was mostly lyrics. Text signals (crew-call words,
  fillers) didn't separate music channels from crew comms, so stage 1 has
  no music check.

Stage 2 keeps a small record of what each channel's audio was like, minute
by minute, so the Review can tell these apart and offer the right fix.

## Goals

- Every session writes a diagnostics file beside its transcript: one row
  per channel per minute.
- The Review uses it to split "barely spoke" into dead input, low level,
  sound that isn't speech, and genuinely quiet; and to add checks for
  music/singing channels, levels that clip, and audio lost because
  transcription or the device fell behind.
- Music and singing are detected with the built-in macOS sound classifier
  (SoundAnalysis), on device, with no model to download.

## Non-goals

- No audio written to disk. Clips for the classifier live in memory only.
  Keeping audio is stage 3 and opt-in.
- No live warnings during a show. No new charts or report tabs; the
  Review tab gains findings.
- No new per-channel settings. Diagnostics are always on (the file is
  small); there is no switch.

## Anti-goals

- Anything on the real-time capture callback. The meter runs in the
  transcriber's read loop.
- Slowing transcription at 32 channels. The classifier is sampled, runs at
  low priority on one shared queue, and drops work rather than queue it
  up. Its cost is measured in `wilco-bench`.
- A check that cries wolf. No session has this file yet, so the
  thresholds below are starting guesses until the first real show is
  recorded (see "Tuning").
- Breaking existing sessions. The transcript format is unchanged; sessions
  without the file get the stage 1 Review as now.

## Approaches

**A. Meter where the engines read audio (chosen).** Every engine (Parakeet
and Whisper through `UtteranceChannelTranscriber` and
`WhisperChannelTranscriber`, and the Apple engine's feed loop) reads its
channel with `source.ring.read`. A meter attached to `AudioSource` sees
every block read, at the capture rate, off the audio thread. It measures
what the engine actually received, which is what explains a bad line. If
an engine fails, its channel's rows stop, and the gap is itself evidence.

**B. A separate tap from the capture callback.** A second ring per channel
with its own reader. Keeps measuring if transcription stalls, but doubles
the work in the real-time callback and can't see the engines' dropouts.
Rejected.

**C. Analyse after the show.** Save compressed audio, analyse it when the
Review opens. Best music detection, but hours of audio on disk, overlaps
stage 3, and does nothing for the sessions already recorded. Rejected.

## Design

### The file

`Session yyyy-MM-dd HHmm-ss.diagnostics` beside the transcript (JSON lines).
It must **not** end in `.jsonl`: `ReportModel` and
`SessionHistory.summaries` treat every `.jsonl` in the transcripts folder
as a session. `SessionDiagnostics.url(forTranscript:)` derives it the way
`SessionShow.url(forTranscript:)` does.

Created on the first row, like the transcript, and appended as each minute
closes, so a crash keeps everything up to the last minute. A session in
which nothing was captured leaves no file.

One JSON object per line, decoded leniently (unknown fields ignored,
missing optional fields nil), with a `v` field (1) on every row so later
versions can add fields:

```json
{"v":1,"channel":"<uuid>","minute":12,"audio":59.9,"sound":21.4,
 "rms":-27.1,"peak":-6.2,"floor":-58.3,"clipped":0,"dropped":0,
 "utterances":7,"speech":18.9,"cuts":0,"recognize":3.1,
 "classified":{"speech":0.91,"music":0.04,"singing":0.02}}
```

| Field | Meaning |
|---|---|
| `minute` | Minute of the session: `floor(offset / 60)`, offset from the session start |
| `audio` | Seconds of audio the engine read this minute. Well under 60 means capture stalled or the engine wasn't reading |
| `sound` | Seconds of 20 ms frames above −46 dBFS (the segmenter's speech floor) |
| `rms` | RMS level of the sound frames in dBFS; null if `sound` is 0 |
| `peak` | Highest sample in dBFS (−∞ written as null) |
| `floor` | 10th-percentile frame level in dBFS: the hiss of an open ring |
| `clipped` | Samples at or above 0.999 |
| `dropped` | Frames the ring dropped this minute because the engine fell behind |
| `utterances`, `speech`, `cuts`, `recognize` | Utterance engines only (nil for Apple): utterances sent to the model, their seconds, how many were cut at the 20 s limit, seconds the model spent on them |
| `partial` | True when the channel's transcriber started, stopped or restarted this minute; absent otherwise |
| `classified` | The classifier's confidence for speech, music and singing on one clip from this minute; nil if the minute had no clip or the classifier was busy |

Muted or unpatched channels aren't transcribed, so they have no rows.

### The meter (`ChannelMeter`, WilcoCore)

A plain struct owned by the transcriber's read loop, so it needs no lock.
`AudioSource` gains `read()`, which reads the ring and feeds the meter, and
the three engines switch from `source.ring.read` to it. The meter:

- splits each block into 20 ms frames (vDSP), adding up sound seconds, sum
  of squares for RMS, peak, clipped count and a small fixed histogram of
  frame levels for the floor percentile (no per-frame storage);
- reads `ring.droppedFrames` at each minute boundary and records the
  difference;
- keeps one classifier clip per minute: the first 3 s run of audio that
  starts with a sound frame, copied into a buffer allocated once at start;
- utterance engines call `meter.recognized(seconds:audioSeconds:cut:)`
  after each model call, which is where `recognize`, `utterances`, `speech`
  and `cuts` come from. The segmenter reports whether a cut was at the
  limit.

At each minute boundary (by the wall clock since the session started, so
dropped audio doesn't shift later minutes) and when the transcriber stops, the meter hands a finished
`ChannelMinute` and its clip, if any, to a sink. A restarted transcriber
gets a new meter for the same channel; the recorder merges two partial
rows for the same channel and minute by adding counts and keeping maxima.

### Music and singing (`SoundClassifierQueue`, WilcoTranscription)

One actor for the whole session, wrapping SoundAnalysis'
`SNClassifySoundRequest(classifierIdentifier: .version1)`. Clips come in
at the capture rate; the classifier takes any PCM format. It keeps the
built-in classifier's `speech`, `music` and `singing` confidences and
ignores the rest of its labels. Work runs at `.utility` priority, one clip
at a time. If more than 64 clips are waiting (two minutes at 32 channels),
new ones are dropped and that minute's `classified` stays nil.

### The recorder (`DiagnosticsRecorder`, app + WilcoCore writer)

Made in `AppModel.startCapture` next to the `TranscriptWriter`, passed to
`TranscriptionController` so every `AudioSource` gets a meter whose sink is
the recorder. It holds each minute until its classification comes back
(or 30 s, then writes it without), merges partial rows, and appends to the
file through a `DiagnosticsWriter` in WilcoCore (same pattern as
`TranscriptWriter`). `stopCapture` flushes it after `stopAll`.

### Reading it (`SessionDiagnostics`, WilcoCore)

`SessionDiagnostics.load(forTranscript:)` returns nil for sessions without
the file. It gives, per channel: minutes with rows, total sound seconds,
the median `rms` over minutes with sound, the share of minutes with
`clipped > 0`, total dropped seconds, minutes where `audio < 50`, and
the share of classified minutes where music or singing beat speech.

`ShowReview.make` gains an optional `diagnostics:`; `ReportModel` loads
the file with the transcript. Every check below skips when it's nil.

### New and changed checks

Starting thresholds, all in `ReviewThresholds`:

| Check | Signal | Fix offered |
|---|---|---|
| Quiet channels (changed) | Same trigger as now. Each listed channel gets a reason: **no input** (peak below −60 dBFS all session: check the patch), **low level** (sound in ≥10% of minutes but median `rms` below −40 dBFS: raise the gain), **not speech** (sound in ≥10% of minutes and music/singing/other beat speech in most classified minutes), or **quiet** (input fine, nobody talked) | None |
| Music channel (new) | ≥30 classified minutes with sound, music or singing beats speech in ≥60% of them | Mute the channel; keep highlights with ≥10 hits off it (as the busy check does) |
| Level too hot (new) | Clipping in ≥5% of minutes with sound | None (gain is on the desk) |
| Level low (new) | ≥30 minutes with sound, median `rms` below −40 dBFS, and the channel isn't in the quiet finding | None; if the unclear check also fired for the channel, its detail says the level may be why |
| Lost audio (new) | Dropped audio of ≥5 s in total on a channel, or a minute with `audio < 50`. A channel's first and last minute, and minutes where its transcriber restarted (the recorder merged partial rows; the row says `"partial":true`), don't count: model loading and stopping leave those short by design | None; the detail names the minutes (and points to falling behind if that fired too) |
| Cut long talk (changed) | Uses the exact `cuts` count when diagnostics exist instead of the text estimate | None |

The music check runs whether or not the show is known, but its fixes, like
the others, need the open show to have the channel.

### Benchmark

`wilco-bench` gains a `--diagnostics` option that runs the meter and the
classifier queue on every channel alongside the engine, so its CPU and
delay columns show the cost at 1–32 channels. The goal: at 32 channels the
classifier keeps up (few or no dropped clips) and adds no more than a few
percent CPU. If it doesn't, cut to one clip every two minutes.

### Tuning

No saved session has a diagnostics file, so the thresholds can't be tuned
the way stage 1's were. A locally gated test (like the one that reviews
every saved session) runs the new checks on every session that has the
file and prints what fired. After the next real show, run it and adjust.
Until then the new findings are in the app but untuned, and PROGRESS.md
says so.

### Later: voice changes

Voice-change detection gets its own spec after stage 3 (real clips give it
a test set; it was tuned only on `say` voices). Seen at the 2026-11-21 show
and in the user's own test: it over-splits. Two people on a channel got
letters up to K, and one person speaking at the same volume and tone was
taken for someone else. The user turned it off on every channel. This
file's `v` field and lenient decoding leave room for per-minute voice
fields then, and its level, floor and music columns let that spec check
whether bad letters cluster on poor audio.

### Docs

`docs/SPEC.md` documents the file format. The show review design doc's
stage 2 section points here.

## Calls made (check these)

- File extension `.diagnostics`, not `.diagnostics.jsonl`, so it isn't
  listed as a session.
- Always on, no setting.
- One clip of 3 s per channel per minute for the classifier; dropped when
  more than 64 are waiting.
- A row waits up to 30 s for its classification, then is written without.
- Minutes follow the wall clock; partial minutes (start, stop, restart)
  are marked and never count as lost audio.
- New checks ship with guessed thresholds and are tuned after the next show.
- The music fix is "mute the channel" (and keep busy highlights off it),
  not something new like "transcribe but don't fire rules". Muting is the
  show-wide knob that exists today.

## Left to the builder

The level histogram's bins, how the minute boundary handles a device rate
change, wording of finding titles and details, the exact `wilco-bench`
output for the classifier, and sample lines chosen as evidence for the new
findings.
