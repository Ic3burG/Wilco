# Transcription benchmark

`wilco-bench` checks whether a speech engine can keep up with a show: many
comms channels at once, live, on one Mac. Use it to compare the engines Wilco
ships, and to try a new model before adding it to the app.

## Running it

From `Packages/WilcoCore`:

```sh
swift run -c release wilco-bench --list
swift run -c release wilco-bench --install parakeet-v2,parakeet-v3   # fetch models the app doesn't manage
swift run -c release wilco-bench                      # every engine that can run here
swift run -c release wilco-bench --engines whisper-base,apple-longform --channels 1,8,16,32
```

Always build in release. A debug build is several times slower and makes
every engine look worse. Quit Wilco and the reference app first, since they
share the speech hardware, and keep the Mac otherwise quiet.

| Option | Default | |
|---|---|---|
| `--engines a,b` | every available engine | See `--list`. |
| `--install a,b` | | Download those engines' models, then exit. For engines the app doesn't manage yet (Parakeet). Apple and Whisper models are installed from Wilco's Languages settings. |
| `--channels 1,8,…` | `1,8,16,32` | One run per count. |
| `--duration S` | `60` | Seconds of audio per run. |
| `--duty F` | `0.3` | Share of time each channel talks. Comms is mostly quiet; `0.6` is a busy ring. |
| `--seed N` | `1` | Who talks when. The same seed gives every engine the same show. |
| `--corpus DIR` | `say` speech | Real recordings: `name.wav` (or `.aif`, `.caf`, `.m4a`, `.mp3`, `.flac`) with `name.txt` holding what was said, one call per file. |
| `--voices N` | `4` | How many `say` voices to use. |
| `--out DIR` | `./bench-results` | JSON and Markdown report, saved after every run (gitignored). |
| `--stop-when-behind` | off | Skip an engine's larger counts once it falls behind. |

## What a run does

1. Builds a schedule for each channel: 40 comms calls ("Standby lighting cue
   forty two", "House to half, please", …). Each channel keys in at its own
   moments, with at least 1.2 s between calls so each one ends cleanly.
2. Starts one transcriber per channel through `ChannelTranscribers.make`,
   the same path the app uses.
3. Writes 48 kHz audio into each channel's 10 s ring buffer in real time,
   the way capture does. It then keeps sending silence until every call has
   a line, or no new line has arrived for 3 s.
4. Scores each channel and records CPU and memory.

## Reading the report

| Column | Meaning |
|---|---|
| WER | Word error rate over each channel's whole transcript. Text is normalised first: case, punctuation, "Q5" = "cue 5" = "cue five", "stand by" = "standby". |
| Missed | Calls with no final line. An engine that merges two calls into one line shows as missed here, but its words still count in WER. |
| Final delay | From the end of a call to its final line. This is when automation can fire. |
| First words | From the start of a call to the first words on screen, partial or final. |
| Backlog | How long after the audio stopped the last line arrived. Growing backlog means the engine is falling behind. |
| Start | Time for all channels to be listening. Includes loading the model. |
| CPU (us) | Cores this process used; 100% is one core. |
| CPU (Mac) | Share of all cores busy, including system speech services. Compare it with the "Mac idle" figure in the header. |
| Dropped | Audio lost because a transcriber didn't read its ring within 10 s. |
| Keeps up | No failures or dropped audio, at most 5% of calls missed, p95 final delay and backlog within 3 s. |

The Neural Engine's load isn't measured: macOS only reports it through
`powermetrics`, which needs root. To see it, run
`sudo powermetrics --samplers ane_power -i 1000` in another window.

**Caveat:** speech from `say` is clean. Real comms has hiss, clipping and
people talking over each other, and will score worse. Use `--corpus` with
recordings from a real show for numbers you'd plan around. The delay and
CPU figures matter more than WER from `say` speech.

## Adding an engine

Engines live in `Packages/WilcoCore/Sources/WilcoBench/BenchEngine.swift`.
Add an entry to `BenchEngine.builtIn` with:

- `id`: the name used with `--engines` and in reports.
- `unavailableReason`: return a short reason when its model isn't on this
  Mac, or `nil` when it can run.
- `install` (optional): download the model, for `--install`.
- `makeFactory`: called once per run. Load or share the model here, then
  return a closure that builds one `ChannelTranscriber` per `BenchChannel`.

A transcriber reads its channel's ring (`channel.source`), calls
`channel.onStatus(.listening)` once it's ready (or `.failed` if it can't
start), and sends `TranscriptionEvent`s to `channel.onEvent`. Set
`sessionOffset` to where the words began, in seconds since the run started.
Send partial text with `isFinal: false` if the engine has it. A candidate
model can be benchmarked this way before it has a `SpeechEngine` case or any
app UI.

**A model that transcribes whole utterances** (most do: Whisper, Parakeet,
Canary, Cohere) needs much less. Conform it to `UtteranceRecognizer` in
`WilcoTranscription`: a `prepare()` that loads it once, and a
`recognize(_:)` that takes 16 kHz mono samples and returns text. Then wrap
it in `UtteranceChannelTranscriber`, which reads the channel, resamples and
cuts at pauses the same way the Whisper path does.
`WilcoBench/ParakeetEngine.swift` is the example. Put the model's package
dependency on the `WilcoBench` target only, so the app doesn't link it until
it's adopted.

## Results

Dated baselines are kept in [`docs/benchmarks/`](benchmarks/).
