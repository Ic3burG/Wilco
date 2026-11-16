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
| `--corpus DIR` | `say` speech | Real recordings: `name.wav` (or `.aif`, `.caf`, `.m4a`, `.mp3`, `.flac`) with `name.txt` holding what was said, one call per file. Lines may start with a speaker mark, `A: `, for voice scoring (see below). |
| `--voices N` | `4` | How many `say` voices to use. |
| `--out DIR` | `./bench-results` | JSON and Markdown report, saved after every run (gitignored). |
| `--stop-when-behind` | off | Skip an engine's larger counts once it falls behind. |
| `--conversation` | off | Channels hold exchanges between voices instead of lone calls (see below). `--duty` doesn't apply. |
| `--voice-threshold D` | the app's default | Voice-change threshold (cosine distance) for the `-voices` engines. |

### Voice changes

The `-voices` engines (`parakeet-v3-voices`, `apple-longform-voices`,
`whisper-base-voices`) are the same engines with voice changes on: each
final line goes to rules at once as `.recognized`, then reaches the screen
with a voice letter once the shared WeSpeaker voice model has looked at it.
They need the voice model (Wilco › Settings, or `--install` with one of
these engines).

`--conversation` gives each channel exchanges of 2–5 turns among 2–4
voices, 0.1–0.8 s between turns, and 25–40 s of quiet between exchanges
(longer than the 20 s exchange gap, so letters start again from A).
Neighbouring turns are always different voices, and voices come back within
an exchange. `say` clips end with about 0.2 s of silence, so gaps under
about 0.5 s fall below the segmenter's 0.7 s pause and two voices end up in
one line. The engines' word timings let such a line be split where the
voice changes; a merged pair counts as a missed change only when it
wasn't split there (within ±0.5 s).

```sh
swift run -c release wilco-bench --conversation \
  --engines parakeet-v3,parakeet-v3-voices --channels 8 --voice-threshold 0.4
```

For a real corpus, mark who speaks each recording: `name.txt` lines start
with a one-letter mark (`A: Standby lighting cue five.`). The same letter in
different files is the same person. A recording is one turn, so all its
marked lines must name the same speaker. `--conversation` then builds
exchanges from the recordings, and needs at least two speakers.

## What a run does

1. Builds a schedule for each channel: 40 comms calls ("Standby lighting cue
   forty two", "House to half, please", …). Each channel keys in at its own
   moments, with at least 1.2 s between calls so each one ends cleanly.
2. Starts one transcriber per channel through `ChannelTranscribers.make`,
   the same path the app uses.
3. Writes 48 kHz audio into each channel's 10 s ring buffer in real time,
   the way capture does. It then keeps sending silence until every call has
   a line (and, with voice changes on, every line its letter), or no new
   line has arrived for 3 s. Stopping the channels annotates any lines still
   waiting for voice analysis; those count too.
4. Scores each channel and records CPU and memory.

## Reading the report

| Column | Meaning |
|---|---|
| WER | Word error rate over each channel's whole transcript. Text is normalised first: case, punctuation, "Q5" = "cue 5" = "cue five", "stand by" = "standby". |
| Missed | Calls with no final line. An engine that merges two calls into one line shows as missed here, but its words still count in WER. In conversation runs, a turn with no line of its own is "merged" (answered by the previous turn's line, not missed) when it is in the same exchange and that line was final only after the turn ended. Lone calls are never merged. |
| Final delay | From the end of a call to its final line. This is when automation can fire. For merged calls, from the end of the last call in the line. |
| Display p95 | From the end of a call to its line on screen. With voice changes on, that's after voice analysis; otherwise it matches the final delay. |
| First words | From the start of a call to the first words on screen, partial or final. |
| Backlog | How long after the audio stopped the last final line arrived (rule lines only). Growing backlog means the engine is falling behind. |
| Start | Time for all channels to be listening. Includes loading the model. |
| CPU (us) | Cores this process used; 100% is one core. |
| CPU (Mac) | Share of all cores busy, including system speech services. Compare it with the "Mac idle" figure in the header. |
| Dropped | Audio lost because a transcriber didn't read its ring within 10 s. |
| Keeps up | No failures or dropped audio, at most 5% of calls missed, p95 final delay and backlog within 3 s. With voice changes on, the display must keep up too: display p95 and display backlog within 3 s. |

Runs of `-voices` engines get a second table, "Voice changes":

| Column | Meaning |
|---|---|
| Changes missed | Turn boundaries where the voice changes (within an exchange) with no change of letter within ±0.5 s. Merged turns count here. |
| False changes | Changes of letter with no change of voice within ±0.5 s. |
| Letters right | Turns by a voice already heard in the exchange that show its earlier letter. |
| No letter | Annotated lines without a letter: too little audio, a short line matching no one, no voice model, or the channel's voice queue (8 lines) was full. The bench can't tell these apart. |
| Not annotated | Recognised lines whose annotation never came. Each counts in the display delay at the moment the run stopped watching, which is a lower bound. |
| Merged calls | Turns that share an earlier turn's line. |
| Display p50 / p95, Display backlog | The voice-analysis delay: when lines reach the screen with their letters. |
| CPU added | This process's cores over the same engine without voice changes, at the same channel count, when both are in the report. |
| Keeps up (cues / display) | The two halves of "Keeps up". Rules never wait for voice analysis, so cues can keep up while the display falls behind. |

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
