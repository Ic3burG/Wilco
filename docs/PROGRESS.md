# Progress

A running log of work on Wilco, one dated section per session, newest last.
Each session ends by adding to it.

Status key: **verified** means tried in the app on a real Mac;
**tested** means covered by automated tests only.

---

## 2026-11-09 → 2026-11-10 — Takeover, spec and first rebuild

### Taking the project over

- The reference app shipped only as a compiled binary; its author handed it
  over with permission. Installed [REA](https://github.com/morluto/rea) and Ghidra and
  analysed a copy of the binary.
- Wrote [`SPEC.md`](SPEC.md): screens, the `.wilco` show format, `.jsonl`
  transcripts, OSC/MIDI/HTTP messages, the `_wilco._tcp` peer protocol, and
  the reference app's known bugs — including the root cause of its crash when deleting a
  channel.
- Chose a clean rebuild from the spec over patching decompiled code, which for
  Swift is unmaintainable.
- New Xcode project under bundle ID `io.github.ic3burg.wilco`, with the
  reference app's licensing (TurboActivate) dropped. Behavioural evidence from the
  original build stays local and out of this public repo.

### Features rebuilt

| Area | What it does | Status |
|---|---|---|
| Show editor | Sidebar of channels, inspector, reorder, autosave; opens existing shows and backs up the original once. Deleting a channel no longer crashes. | verified |
| Audio capture | Drives the interface directly with per-channel meters; rebuilds capture if the driver stalls or the device is unplugged. Several input devices at once, chosen from the sidebar. | verified |
| Transcription | Each channel transcribed on-device by Apple's speech engine (macOS 26+) or Whisper; transcripts written as `.jsonl`. | verified |
| Automation | Phrase rules fire OSC (UDP / TCP / SLIP), MIDI, webhooks, notifications and cue markers; highlights in the transcript; Activity log. | tested |
| Post-show report | Run of show, chat log and Channels tabs in the reference app's style: stats header, channel and moment chips, search with `"exact phrases"`, per-channel stats and a traffic heatmap. Export to HTML, SRT and VTT. Statistics checked against the reference app's own report for a real session. | built, awaiting user test |
| Look & Feel | Text size, timecode, newest-first, follow live; matrix column widths/collapse/text size (in the matrix toolbar and column headers); Light, Dark or Match System. Imports existing preferences once. | built, awaiting user test |
| Live transcript | Restyled to match the report: live header with duration and counts, channel chips, clock-over-elapsed time column. | built, awaiting user test |
| HTML export | Self-contained page mirroring the report window, light/dark aware, printable, opens to a tab via `#view=`. | built, awaiting user test |

### Fixes worth knowing about

- **Negative device input indexes** could reach the audio thread; now rejected
  before capture starts.
- **Spoken text in OSC addresses** is sanitised so a transcript can't produce
  an invalid address pattern.
- **Calls split by the speech engine** ("Stand by" for *Standby*, "house
  lights" for *houselights*) are now found and highlighted everywhere, without
  matching inside other words.
- **OSC over TCP to a silent console** used to wait for macOS's 75-second
  connect timeout instead of the intended 2 seconds. Cancelling a send now
  closes its connection. Found by CI.

### Tooling

- GitHub Actions CI (`.github/workflows/ci.yml`): package tests and an unsigned
  app build on every push and pull request, about 2 minutes.
- 111 automated tests at the time. Tests needing a real show, real transcripts or real
  speech skip themselves unless that data is present (`WILCO_ASR_TESTS=1`
  enables speech).
- Documentation: this progress log (added to at the end of every session),
  a README covering status, building, tests and layout, and a description
  and topics on the GitHub repo.

### Next steps / where we left off

- **User testing:** the report restyle, Look & Feel, live transcript and HTML
  export need trying in the app.
- **Moment detection** finds more markers than the reference app did (37 vs 26 on one
  session); tighten the phrase lists if the extras are noise.
- **Not yet rebuilt** (choose next): peer sharing between Macs (`_wilco._tcp`),
  MCP server, MOS, automatic updates via Sparkle, Vor preset.
- **CI Xcode** is 26.6, older than the local 27.2: anything needing the
  Xcode 27 SDK must be guarded or CI will fail.

## 2026-11-11 → 2026-11-12 — Languages, translation and Whisper speed

### Features

- **Language menu.** A channel's language is now a menu of the languages its
  engine supports, with readable names ("English (United States)", not
  `en_US`). Whisper adds **Detect Automatically**; Apple's engines can't
  detect a language, so they don't offer it.
- **Translate to English** (Whisper channels only). Combined with Detect
  Automatically, a channel writes English whatever language is spoken.
  Tested with a French clip read by the Mac's French voice. Older show files
  open with it off.
- **Settings → Languages**, laid out like the reference app's: Global Vocabulary, the
  shared Whisper model (picker, model descriptions, Install with progress),
  and Speech Models: one row for each language and engine the channels use,
  with Installed / Install / Not available. Unlike the reference app it can also
  **remove** Whisper models that aren't in use, and release long-form
  languages no channel needs (macOS deletes those once no other app uses
  them). Downloads carry on if Settings is closed.

### Fixes

- **Whisper lines were 20–70 s late and duplicated.** Whisper itself is fast
  (0.2–0.7 s for a 7 s clip on an M1 Max); two bugs around it were not:
  - An Apple channel that never received audio (patched to a device that
    isn't running, such as Dante DVS) could never be stopped. Stopping a
    session handled channels one at a time, so channels after it kept
    running. On the next start the old and new Whisper transcribers both read
    the same audio buffer. Now such a channel is cancelled, and all channels
    stop side by side.
  - The utterance cutter only learned the background level between
    utterances, so noise starting mid-speech held every line open to the
    20 s limit. It now keeps learning during speech from the quietest moment
    of the last second.

### Tooling

- 125 automated tests, including regression tests for both fixes and a
  real-speech test of French detected and translated to English
  (`WILCO_ASR_TESTS=1`).

### Next steps / where we left off

- **User testing:** the Languages tab (install, remove, progress) and a
  translating channel need trying in the app.
- **Optional speed-ups offered:** load the Whisper model at launch or when
  it's picked (Small takes ~48 s to load, Base ~16 s), and lower the 20 s
  chunk limit to about 10 s.
- **Next session:** the user is starting a new feature. Still not rebuilt:
  peer sharing (`_wilco._tcp`), MCP server, MOS, Sparkle updates, Vor preset.
- Quit the reference app while testing; it shares the audio input and speech
  hardware.

## 2026-11-12 — Sidebar alignment and Configurations

### Fixes

- **Sidebar rows were centred.** The headers and Combined / Matrix / Activity
  sat in the middle of the sidebar after the move to the AppKit outline:
  rows without a spacer were centred in their cell. Rows are now
  left-aligned. Verified by the user.

### Features

- **Configurations** (new; the reference app had nothing like it, the idea comes from
  ProdCom). A configuration is a whole saved show: channels, folders,
  inputs, device, rules, highlights, OSC destinations, vocabulary and
  Whisper model.
  - Click the window title to switch, Save (⌘S), Save As New (⇧⌘S),
    Revert to Saved or Manage Configurations (⇧⌘O). The title says
    "— Edited" when the show differs from what was saved.
  - Loading works like a snapshot recall. Edits stay in the working copy
    (still autosaved to `Current.wilco`) until you Save. Loading is refused
    while capturing, asks Save / Don't Save / Cancel if there are unsaved
    changes, and clears the on-screen transcript and activity (the session
    file on disk keeps every line). Cue markers are kept.
  - The Configurations window lists them with channel count and save date:
    New, Duplicate, Rename, Delete (not the loaded one), Import and Export
    `.wilco` files.
  - The first launch turns the current show into the first configuration.
    Stored in `Application Support/Wilco/Configurations/`, one plain
    `.wilco` per configuration; the show format is unchanged.

### Tooling

- 22 new package tests for the configuration store and rules (194 in all).
- Whole-branch review: two fixes. A configuration file deleted in Finder
  while Wilco runs now turns the show "Not Saved" instead of letting a
  load replace it unasked. Loading no longer throws away cue markers,
  which exist only in memory.
- Design: `docs/superpowers/specs/2026-11-12-configurations-design.md`;
  plan: `docs/superpowers/plans/2026-11-12-configurations.md`.

### Next steps / where we left off

- **User testing (configurations are "tested", not yet verified):** save two
  setups and switch between them; check the patch, rules and OSC
  destinations all swap and the transcript clears; try loading while
  capturing (refused); watch "— Edited" appear and clear when a change is
  undone; export one, import it back.
- Check that the title menu appears on the window title next to the
  inspector toolbar. If it doesn't, fall back to a title-styled toolbar menu.
- **Pull request #1** (`feature/configurations` → `main`) carries the
  AppKit sidebar, the alignment fix and configurations. Merge it once the
  in-app checks above pass.
- **Deferred minors from the review** (in the PR description): Save in the
  unsaved-changes prompt for a "Not Saved" show drops the requested load;
  Save As New renumbers a taken name silently; an error can show in both
  windows; a vanished configuration gives a generic error.
- `CLAUDE.md` is still untracked in git.

## 2026-11-12 (evening) — Configurations: first in-app fixes

PR #1 (AppKit sidebar, alignment fix, configurations) was rebase-merged
into `main`. The 11 channel-groups commits that were only local are now on
GitHub too, with the same content. The old local `main` is kept as the tag
`backup/local-main-before-pr1`.

### Fixes

- **Manage Configurations crashed** ("No Observable object of type
  AppModel"). The dialogs modifier was applied outside the window's
  `.environment(model)`, so it couldn't see the model. It now lives
  inside `ConfigurationsWindow`. Found by the user in the app.

### Features

- **Configurations toolbar button** (`rectangle.stack`), one click to the
  Configurations window. It sits on the detail column; on the split view
  it fell into the toolbar's `>>` overflow menu. The title menu stays as
  it was.
- **Save Changes** button in the Configurations window, next to Load. It
  saves the loaded configuration (not the selected row) and is greyed out
  while nothing has changed.
- **Shortcuts:** Add Channel is now ⌘N (was ⇧⌘N); New Group is ⇧⌘N.
- **Translate to English** now sets the language to Detect Automatically.
  A language picked afterwards is kept, and turning translation off
  leaves the language alone. Two new tests (196 in all).

### Next steps / where we left off

- **Finish the configurations checklist in the app:** switching between
  two setups swaps the patch, rules and OSC; loading is refused while
  capturing; "— Edited" clears after ⌘S or Save Changes; export, then
  import. Mark configurations "verified" once that's done.
- **Deferred minors** (unchanged, see PR #1): Save in the unsaved prompt
  for a "Not Saved" show drops the requested load; Save As New renumbers a
  taken name silently; an error can show in both windows.
- **Tidy up:** delete the merged branches `feature/sidebar-outline` and
  `feature/configurations` (local and remote) and the backup tag when
  happy. `CLAUDE.md` is still untracked.

## 2026-11-12 (night) — New name and identity: Wilco

The project is now **Wilco**, in a new private repo `Ic3burG/Wilco` that
starts from a single fresh commit.

### Identity

- App, scheme, project, folders, package and modules: `Wilco`,
  `Wilco.xcodeproj`, `Packages/WilcoCore` with `WilcoCore`, `WilcoAudio`,
  `WilcoTranscription` and `WilcoControl`, and `WilcoJSON`.
- Bundle ID `io.github.ic3burg.wilco`, Bonjour `_wilco._tcp`, CoreMIDI
  client "Wilco" / "Wilco Out", queue labels, the sidebar pasteboard type,
  the default OSC and webhook examples (`/wilco/...`), the new-show MOS ID,
  the Sparkle feed URL, and the test variables `WILCO_ASR_TESTS` and
  `WILCO_EXPORT_DIR`.
- Shows are saved as `.wilco` (same JSON, `formatVersion` 1) in
  `~/Library/Application Support/Wilco`, which also holds Transcripts and
  WhisperModels.
- The user's existing shows, configurations, transcripts, Whisper models
  and preferences were moved into the new folder and preferences domain once,
  on this Mac. The app has no import code for older locations.
- `ShowStore` no longer makes a one-time backup of the show file.
- Copyright in the app is now "Copyright © 2026 Omar Davis".
- **New app icon:** an amber waveform that settles into lines of text, with
  an "acknowledged" check badge, on a midnight-navy tile. Generated from a
  prompt, then fitted to Apple's grid (824px tile on a 1024 canvas, made
  fully opaque, soft drop shadow) and exported at every size. It reads
  clearly down to 32px; at 16px it's just a shape. It replaces the
  inherited headset.
- No version number or name for the reference app anywhere in the project.
  Docs call it "the reference app". Code comments explain behaviour on its
  own terms (e.g. why the inspector never stores an array index). Two
  tests were renamed (`importsFormatV1Fixture`,
  `mscGoUsesLightingGeneralFormat`).
- Format fixtures renamed `show-v1.wilco` and `session-v1.jsonl`; the
  format suite is now `FileFormatTests`. 195 tests, passing; the app builds
  with no new warnings.
- Fixed two compiler warnings in `TranscriptionTests` (an `await` on the
  synchronous `isDownloaded`). The package now builds with no warnings.

### Next steps / where we left off

- **Verify in the app:** Wilco opens with the show, configurations,
  transcripts, Whisper models and look & feel all in place.
- The local-only branch `old-history` keeps the pre-squash commits. Delete
  it (`git branch -D old-history`) once it's no longer wanted.
- Configurations checklist and deferred minors from the previous section
  are unchanged.
- Rename the local folder `~/Projects/Wilco` to `~/Projects/Wilco` when
  convenient. (Claude Code's memory for this project is keyed by the path.)

## 2026-11-12 (late) — Choosing speech models and a 32-channel benchmark

### Research: other speech models

The goal is 32 channels transcribed at once, on one Mac. Four suggested
models were checked against that:

- **Moonshine Voice** (MIT, Swift package with a macOS build). It streams
  partial results, but one loaded model handles its streams one at a time,
  and its own docs warn that 10 or more streams slow it down. It's unlikely
  to reach 32 channels; not pursued for now.
- **Canary-Qwen 2.5B** and **IBM Granite Speech 3.3** are large models that
  pair a speech encoder with a language model. Neither streams or has an
  official Mac build, and neither can serve 32 live channels. Ruled out.
- **NVIDIA Parakeet TDT 0.6B v3** (CC-BY-4.0) is the best candidate. The
  FluidAudio Swift package runs it on the Neural Engine at about 210× real
  time. It transcribes a finished utterance the way our Whisper path does,
  so one shared model could serve every channel.

### Tooling

- **`wilco-bench`**, a multichannel transcription benchmark (new
  `WilcoBench` library and command-line tool in `Packages/WilcoCore`).
  - It plays a seeded scenario of comms calls into many channels in real
    time, through the same 48 kHz ring buffers and `ChannelTranscribers.make`
    path the app uses.
  - It reports word error rate, delay from the end of a call to its final
    line, first-words delay, missed calls, backlog, CPU, memory and dropped
    audio, plus a "keeps up" verdict.
  - Speech comes from `say` in several voices (cached), or from a folder of
    real recordings (`--corpus`).
  - A new model is one `BenchEngine` entry, so a candidate can be measured
    before it exists in the app. How to run and extend it:
    [`BENCHMARK.md`](BENCHMARK.md).
- 21 new package tests: text normalising ("Q5" = "cue five"), word error
  rate, scenarios, scoring, the runner and the report (216 in all).

### Baseline: where we land today

M1 Max, 60 s runs, 30% talk time, `say` speech. Full table:
[`benchmarks/2026-11-12-m1-max-say.md`](benchmarks/2026-11-12-m1-max-say.md).

- **Whisper base** keeps up at 32 channels. Lines arrive 0.76 s after a
  call ends (0.91 s for the slowest 5%), the same as at 1 channel.
- **Apple long-form** (the default "fast, then corrected" setting) keeps up
  at 32 channels: 0.93 s median, 1.66 s for the slowest 5%, with one call
  missed out of 253.
- **Whisper small** is the most accurate (3–5% WER) up to 16 channels, but
  falls behind at 32 (7 s for the slowest 5%).
- **Apple long-form "one pass"** isn't overloaded but is slower at every
  channel count, about 2.2 s median. The "fast, then corrected" setting gets
  final lines out sooner.
- **Apple dictation** is a poor fit: 11–17% WER, and up to 13% of calls
  missed.
- Load doesn't change accuracy: channel 1's transcript was the same at 8,
  16 and 32 channels.
- `say` speech is a best case; real comms will score worse.

### Found along the way

- `SpeechAssets.status` reports an installed Apple model as only
  "supported" to a process that hasn't reserved it. The benchmark checks
  installed locales instead. The app may show "Install" for a language
  another app already downloaded (installing it is then instant). Minor.

### Next steps / where we left off

- **Add Parakeet TDT v3** (through FluidAudio) as a benchmark engine and
  measure it at 32 channels. To be worth adopting, it needs better accuracy
  than Whisper small while keeping up at 32 channels like Whisper base.
- **Benchmark real comms audio:** collect recordings from a show
  (`name.wav` + `name.txt`) and run with `--corpus`. Those numbers are the
  ones to decide on.
- Consider the Apple "one pass" profile's name and description, since it's
  slower than the default, not lighter.
- Unchanged from earlier: configurations checklist in the app, deferred
  minors, delete `old-history` when no longer needed.

## 2026-11-13 — Parakeet in the benchmark

### Tooling

- **Parakeet TDT 0.6B v2 and v3** are benchmark engines (`parakeet-v2`,
  `parakeet-v3`), run through FluidAudio 0.18.3 on the Neural Engine. One
  model serves every channel. FluidAudio is a dependency of `WilcoBench`
  only, so the app doesn't link it yet.
- **`UtteranceRecognizer` and `UtteranceChannelTranscriber`** (in
  `WilcoTranscription`): a model that transcribes whole utterances now only
  needs `prepare()` and `recognize(samples)`. The transcriber reads the
  channel, resamples to 16 kHz and cuts at pauses, as the Whisper path
  does. Parakeet is the first user; it's how the app would adopt it.
- **`wilco-bench --install a,b`** downloads models the app doesn't manage
  (Parakeet).
- **Voice selection** matches `say` voices by name and locale, preferring
  the standard voice over Enhanced/Premium ones. macOS had renamed
  "Samantha" to "Samantha (English (US))", which dropped her from the set
  without warning. Runs now use Samantha, Daniel, Karen and Moira.
- 4 new package tests (voice listing, voice picking, the utterance
  transcriber, a model that fails to load); 220 in all.

### Results

M1 Max, 60 s runs, `say` speech. Full tables:
[`2026-11-13-m1-max-say.md`](benchmarks/2026-11-13-m1-max-say.md) (every
engine, 30% talk time) and
[`2026-11-13-m1-max-say-64ch.md`](benchmarks/2026-11-13-m1-max-say-64ch.md)
(32 and 64 channels, 60% talk time).

At 32 channels, 30% talk time:

| Engine | WER | Missed | Final delay p50 / p95 | Keeps up |
|---|---:|---:|---|:---:|
| parakeet-v3 | 3.1% | 0/266 | 0.67 / 0.77 s | yes |
| parakeet-v2 | 3.9% | 0/266 | 0.68 / 0.76 s | yes |
| apple-longform | 6.6% | 1/266 | 0.95 / 1.64 s | yes |
| whisper-base | 7.4% | 0/266 | 0.76 / 0.95 s | yes |
| whisper-small | 1.6% | 0/266 | 5.90 / 7.44 s | no |
| apple-longform-single | 5.2% | 0/266 | 3.67 / 8.59 s | no |
| apple-dictation | 11.0% | 30/266 | 2.08 / 3.46 s | no |

- **Parakeet meets the bar set last session**: as fast as Whisper base at
  32 channels, and more accurate than everything that keeps up. Its delay
  is flat from 1 to 32 channels.
- **Only Parakeet keeps up at 64 channels** on a busy ring (60% talk):
  parakeet-v2 had 4.3% WER, 0 missed, 0.75 s p95, using 77% of one core.
  Whisper base fell behind there (12 s p95, dropped audio); Apple long-form
  kept up but at 15.9% WER.
- **v2 against v3** depends on the voices: v2 was ahead with the earlier
  voices (5.4% vs 7.4%), v3 with these (3.1% vs 3.9%). Call it a tie on
  English; v3 also covers 25 languages.
- Whisper small is still the most accurate, but only up to 16 channels.
- Whisper base missed the "keeps up" bar once at 16 channels (3.1 s p95)
  but passed at 32. Probably a one-off stall; worth watching.
- First load of a Parakeet model takes about 26 s (compiling for the Neural
  Engine); later loads take 0.2 s.
- Still `say` speech, a best case. WER can only be compared within one run,
  since the voices changed between runs.

### Found along the way

- Moving or renaming the project folder breaks the package build:
  `.build` keeps absolute paths to FluidAudio's binary frameworks. Deleting
  `Packages/WilcoCore/.build` fixes it.

### Next steps / where we left off

- **Benchmark real comms audio** (`--corpus`) for Parakeet v2/v3, Whisper
  base and Apple long-form. Those numbers decide whether to adopt Parakeet.
- If Parakeet holds up: add it as a `SpeechEngine` in the app, with model
  download in the Languages settings, through `UtteranceChannelTranscriber`.
  Decide v2 (English) or v3 (multilingual), or offer both.
- Check FluidAudio's licence and the Parakeet model's CC-BY-4.0 attribution
  before shipping it.
- Unchanged from earlier: Apple "one pass" profile naming, configurations
  checklist in the app, deferred minors, delete `old-history` when no
  longer needed.

## 2026-11-13 (in progress) — Parakeet vocabulary benchmark

Run on 2026-11-15, `say` speech, 60 s per run, on AC power with the Mac
kept awake (`caffeinate`). Both engines build one recognizer per channel
over one shared model store, as the app does. Full table in
`docs/benchmarks/2026-11-13-m1-max-say-parakeet-vocab.md`.

| Engine | 32 ch WER | Missed | p95 delay | CPU (us) | Keeps up |
|---|---:|---:|---:|---:|:---:|
| parakeet-v3 | 3.1% | 0/266 | 0.75 s | 40% | yes |
| parakeet-v3-vocab | 2.6% | 0/266 | 0.76 s | 42% | yes |

- **Decision: vocabulary boosting keeps up at 32 channels**, so the per-channel
  "Use vocabulary" switch (Task 6) is skipped.
- Boosting didn't make WER worse at any channel count: 38 word errors
  against 46 at 32 channels, no deletions with or without it. Most of
  what's left is numbers written as digits ("Q42" for "cue forty two").
  The bench's terms are words Parakeet mostly hears right already, so this
  says little about rarer show words.
- Boosting adds about 0.3 s to start-up (loading the CTC model) and ~2% of
  one core at 32 channels.

### Found along the way

- An earlier run (2026-11-13) looked broken: 50/60 calls missed at 8
  channels with 1% CPU, millions of dropped frames at 32, a 31-minute
  start for the vocabulary engine. Not a code defect. The power log shows
  the Mac went into clamshell sleep on battery a minute after the run
  started and stayed in sleep/dark-wake cycles for two hours. The CTC
  model had finished downloading 17 minutes before the run. A repeat at 8
  channels with the Mac awake was clean (0/29 missed for both engines).
- Long benchmarks need the lid open or the Mac on power with
  `caffeinate -dims`.

## 2026-11-15 (in progress) — Voice change benchmark

`wilco-bench --conversation` gives each channel exchanges between voices:
2–5 turns among 2–4 `say` voices, 0.1–0.8 s between turns (the shorter gaps
merge into one line), 25–40 s between exchanges. The `-voices` engines
(`parakeet-v3-voices`, `apple-longform-voices`, `whisper-base-voices`) run
with voice changes on and get a second table: missed and false voice
changes, letters right for returning voices, lines without a letter,
annotations that never came, merged calls, and display delay and backlog.
`--voice-threshold` sets the threshold. Corpus transcripts can mark the
speaker with `A: ` at the start of a line. Tested, not verified.

Fixed in the bench: backlog and "keeps up" counted the voice annotations as
final lines. Cue backlog now counts rule lines only, and `-voices` engines
must also keep the display within 3 s (p95 and backlog). Annotations that
never arrive are counted, and they count in the display delay at the time
the run stopped. A conversation turn with no line of its own counts as
"merged", not missed, when it's in the same exchange as the turn before
and that turn's line was final only after it ended. The line's delay then
runs from the end of the last turn in it. Lone calls are never merged.

Full table: `docs/benchmarks/2026-11-15-m1-max-say-voices.md`. At 32
channels (re-run after the scoring was tightened):

| Engine | Changes missed | False | Letters right | Final p95 | Display p95 | Keeps up |
|---|---:|---:|---:|---:|---:|:---:|
| parakeet-v3-voices | 81/134 | 0 | 80% | 0.73 s | 0.89 s | yes |
| apple-longform-voices | 30/134 | 3 | 87% | 1.92 s | 2.03 s | yes |
| whisper-base-voices | 81/134 | 0 | 79% | 2.01 s | 2.27 s | yes |

- **New channels detect voice changes by default.** Channels in existing
  shows open with it off. Every `-voices` engine kept up at 32 channels in
  the re-run. Tested, not verified.
- **Apple long-form at 32 channels varies from run to run**, with voice
  changes on or off. Over four 32-channel runs `apple-longform-voices`
  kept up three times, and plain `apple-longform` once (final p95 1.7–9.7 s).
  Voice changes don't make it worse; the engine is the limit there.
- Voice changes cost 7–11% of one core at 32 channels, and the display
  trails the final line by 0.1–0.3 s. With Whisper the final p95 rose from
  about 1.0 s to 2.0 s, probably because the voice model and Whisper share
  the GPU.
- The app has no voice model install button yet. Without the model, lines
  get no letter but carry on as normal.
- Threshold stays 0.5. At 8 channels, 0.4 / 0.5 / 0.6 gave 48 / 53 / 56
  missed changes of 85 and 77% / 94% / 97% letters right, with no false
  changes at any of them.
- Most missed changes are merged turns (63 of Parakeet's 81 at 32
  channels), since a line keeps one letter for now. Splitting lines where
  the voice changes is next, and this run is the baseline for it.
- `say` voices are far more distinct than real people. The threshold needs
  checking on real comms.

## 2026-11-16 (in progress) — Splitting lines where the voice changes

- A line whose voice changes partway (a call and a quick "standing by" with
  no pause) now comes back as several lines, each with its own letter and
  time. The cut goes in the gap between words nearest the change.
  `LineSplitter` in WilcoCore does this from each engine's word timings:
  Parakeet's token timings, Whisper's word timestamps (asked for only when
  voice changes are on), and Apple's `audioTimeRange` per word. The text
  sent to rules is unchanged. When a line has no timings, or they don't
  match its text, it stays whole and takes its longest piece's letter.
- Parakeet vocabulary fixes keep their word timings when the word count is
  unchanged. When two words became one term, the line isn't split.
- The tracker placed changes about 0.75 s early, at the start of the first
  1.5 s voiceprint window that differed. It now puts them halfway between
  the middles of the last old and first new windows.
- Apple's 16 kHz voice history now advances by the audio it was fed even if
  its resampler fails, so later lines still find their own audio.
- Gated tests: a call and answer in two `say` voices with no pause come back
  as A then B on Parakeet and Whisper (one line, split). Apple long-form
  ends the line at the change by itself, so it gives A and B as two lines.
- 32 channels (`docs/benchmarks/2026-11-16-m1-max-say-voices-split.md`):
  missed changes 81 → 53 (Parakeet), 81 → 51 (Whisper), 30 → 30 (Apple),
  with 2, 0 and 3 false changes. All three keep up. Whisper's final p95 rose
  to about 2.4 s with word timestamps on, still under 3 s. Tested, not
  verified.

## 2026-11-16 — Parakeet in the app, vocabulary and voice letters

Built on branch `feature/parakeet-voices` from the design in
`docs/superpowers/specs/2026-11-13-parakeet-vocabulary-voice-changes-design.md`
and the plan beside it. Every task was reviewed, then the whole branch.
All of it is tested, none of it verified in a real show yet.

### Features

- **Parakeet TDT v3** is a fourth engine in the Inspector. One model on the
  Neural Engine serves every Parakeet channel. It detects 25 European
  languages, or takes the channel's language as a hint. New Parakeet
  channels start in English. Its model (and the vocabulary model) install
  and remove from Settings → Languages; a channel that failed because the
  model was missing restarts by itself once it's installed.
- **Vocabulary on Parakeet** (English channels only): the show's terms and
  rule phrases are boosted with FluidAudio's separate vocabulary model. A
  boosted line is thrown away if it would change, add or drop a number, so
  vocabulary can never invent a cue number. Terms under 3 characters are
  ignored. The Inspector says when vocabulary doesn't apply.
- **Voice letters** on every engine: each line is marked A, B, C… for its
  voice within the current exchange; letters start again after 20 s of
  silence. A line whose voice changes partway is split between words.
  Letters show in the transcript (a new voice starts a visible new turn),
  the HTML report and SRT/VTT exports ("B: Standing by"). Lines from
  sessions or channels without letters look as before.
  - New channels have voice changes on; channels in existing shows open
    with them off. Settings → Languages has the voice model, "Telling
    voices apart" (Stricter ←→ Looser) and "New exchange after". Changing
    them mid-show takes effect from the next line without restarting
    anything.
  - Rules still fire on the recognised line straight away; the letter
    follows for the transcript, the session file and reports. `{voice}` is
    empty at rule time.
  - Voiceprints stay in memory only. Session files store just the letter
    and an exchange number (optional fields; older files are unchanged).
- Credits (About panel) for FluidAudio, WhisperKit and the NVIDIA and
  pyannote models.

### Fixes from review

- Unknown engine names in a show (from a newer build) fall back to the
  default engine instead of failing the whole show.
- Moving the voice settings slider no longer restarts every channel.
- Without the voice model, Whisper and Apple skip the extra work (word
  timestamps, a second resampler) instead of paying for letters they can't
  give.
- Each channel's voice queue holds at most 8 lines; extras go out without a
  letter rather than piling up audio.

### Numbers (32 channels, `say` speech)

- Parakeet with vocabulary: 2.6% WER, nothing missed, p95 0.76 s.
- Voice letters: 80–87% of returning voices get their old letter; line
  splitting cut missed voice changes from 81 to 53 (Parakeet) and 51
  (Whisper). All three engines keep up. Whisper's cue p95 rises from about
  1.0 s to 2.4 s with voice changes on (still under 3 s).
- Apple long-form at 32 channels varies from run to run in busy
  back-and-forth, with or without voice changes.

### Next steps / where we left off

- **Try it in a real show:** Parakeet channels, the Install buttons, voice
  letters on a busy party line, the settings, and a report.
- **Benchmark real comms** with `--corpus`, marking speakers with `A: `,
  to tune the voice threshold and check vocabulary on rarer show words.
- Decide whether new Whisper channels should start with voice changes off
  (cue delay trade-off above).
- Push the branch so CI builds it with Xcode 26.6 before merging.
- Deferred minors are listed in the final review; none block use.

## 2026-11-16 — One show vocabulary, Parakeet boosting fix, Automation settings

### Features and changes

- **Show vocabulary only.** Channels no longer have their own vocabulary;
  the Inspector section is gone and Settings → Languages → Global
  Vocabulary is the one list. A show that has terms on its channels moves
  them into the show's list when it opens (trimmed, case-insensitive
  duplicates skipped), so nothing is lost or left hidden. The Inspector
  still says when a non-English Parakeet channel won't boost the
  vocabulary.
- **Automation settings tidied.** The rules and highlights list is a
  bordered list beside the editor instead of a full-height sidebar, which
  ran up under the toolbar and covered the first tab. Phrases have their
  own section; Match, Channels and Cooldown sit together under "When".
  Footers are one line each.
- **Word list fields** (rules, highlights, Global Vocabulary) show the
  prompt inside a visible text field with a + button. In a grouped form the
  prompt used to show as a row label beside an invisible field.

### Fixes

- **Parakeet vocabulary was replacing correct words.** In a real session
  with four short terms, "a little bigger" came back "a little Panel",
  "Okay" became "Omar" and "the dictionary" became "the Panel". Parakeet's
  own text was as good as Whisper's; the vocabulary booster spoiled it.
  For vocabularies of 10 terms or fewer FluidAudio runs an acoustic-only
  "rescue" pass with no similarity check, so our 0.7 similarity floor
  never applied to it. The rescue is now off.
  - 112 `say` clips (4 voices, clean and with noise): terms inserted where
    nobody said them went from 30 to 0; spoken terms kept went from 31 to
    23 of 72. The cost is badly misheard names ("kineses" stays "kineses").
    A made-up term can be a rule phrase and fire a cue, so a miss is the
    better failure.
  - A similarity floor on the rescue (0.4–0.6) was tried: 0.4 still
    inserted "Omar" for "Okay"; 0.6 behaves like off.
  - Regression test with real terms and lines that failed on clean audio;
    it fails with the old setting.

### Numbers (`say` speech, 8 channels)

- Parakeet 1.3% WER, Parakeet with vocabulary 0.8%, Whisper base 5.5%;
  nothing missed, p95 0.77–0.92 s. Clean `say` speech rarely triggered the
  bad replacements, so this shows boosting still helps rather than proving
  the live-mic fix.

All of this is tested, not verified.

### Next steps / where we left off

- **Try it in the app:** speak on a Parakeet channel with the show's
  highlight words and check nothing is substituted; look over Settings →
  Automation and the new add fields.
- Open a show that had channel vocabulary and check the terms appear in
  Global Vocabulary.
- **Benchmark real comms** with `--corpus` to measure vocabulary recall
  on live-mic audio; if names are missed too often, consider a narrow
  rescue only for long, distinctive terms.
- Earlier items still open: real-show test of voice letters, the voice
  threshold, and whether new Whisper channels start with voice changes off.

## 2026-11-16 — Parakeet live preview

### Features

- **Parakeet shows words as they are spoken.** On a Parakeet channel set
  to Latency "Fast, then corrected" (the default, so existing Parakeet
  channels get it), the call still being spoken is transcribed again
  about every 0.5 s and shown in italics, then replaced by the final line
  at the pause, as on Apple channels. Previews start after 0.5 s of
  speech, stop once a pause reaches 0.3 s, skip vocabulary boosting and
  only reach the screen, not rules or outputs. "Single pass" turns them
  off. The Latency picker is now enabled for Parakeet; Whisper still has
  no preview.
- **Final lines keep priority.** All Parakeet channels share one model. A
  preview runs only while no channel's final line is being transcribed,
  and otherwise is skipped rather than queued (`PreviewGate`). Final
  lines never wait for the gate; at most one may wait behind a single
  preview already running.
- Design and plan: `docs/superpowers/specs/2026-11-16-parakeet-live-preview-design.md`,
  `docs/superpowers/plans/2026-11-16-parakeet-live-preview.md`. SPEC §6
  updated.

### Fixes

- **Stopping capture mid-call dropped the call's last line on Parakeet.**
  The flush ran in the cancelled pump task, and Parakeet's pipeline checks
  for cancellation, so the line was lost (this predates previews). The
  flush now runs in a task of its own. With previews, the lost line would
  also have left italics on screen.
- **Italics left behind.** If a previewed call's final line comes back
  empty or fails, the channel's words in progress are now cleared.
- Both found by the final review, each with a regression test.

### Tooling

- `wilco-bench` engines `parakeet-v3-preview` and
  `parakeet-v3-preview-voices`.

### Numbers (`say` speech, M1 Max)

- 32 channels: final p95 0.84 s with preview against 0.74 s without (bar:
  within 0.25 s); median time to first words 2.9 s → 1.7 s; CPU 39% → 62%
  of a core. One channel: first words 2.9 s → 0.7 s.
- Conversation with voice changes, 32 channels, three alternating rounds:
  preview equal or better every time (final p95 0.72–0.78 s against
  0.74–0.82 s; first words 3.1 s → 2.2–2.5 s).
- Three earlier runs stalled: every Neural Engine call slowed for 7–18 s,
  **with or without preview**. Cause not confirmed; candidates are macOS
  speech services and running without `caffeinate`. Details in
  `docs/benchmarks/2026-11-16-m1-max-say-preview.md`.

All of this is tested, not verified.

### Found in app testing (after the above)

The user compared Long-form, Whisper and Parakeet on the same built-in
mic. Parakeet and Whisper both **miss stretches of speech** that
long-form keeps, and long-form builds better sentences. Across the four
sessions of 2026-11-16, Parakeet captured 132–417 words and Whisper
161–342 against long-form's 253–532: roughly 50–80%. Parakeet and Whisper
lose the *same* stretches, and the sessions before previews existed show
it too, so the model and the previews aren't the cause.

**Root cause (reproduced, not yet fixed): `UtteranceSegmenter`'s noise
floor locks out continuous speech.** Both utterance engines cut audio
with it; Apple long-form streams without it.

- During speech, `learnFloorDuringSpeech` raises the floor to the
  quietest frame of the last 1 s. Continuous talking has no truly quiet
  frame in 1 s, so the floor climbs to speech level. Speech needs
  `rms > 4 × floor`, so ordinary speech starts counting as silence, and
  after 0.7 s the utterance ends mid-sentence.
- Between utterances, `noiseFloor = 0.95 × floor + 0.05 × rms` learns from
  every frame not judged speech, including speech now under the
  threshold. The floor stays at speech level and further talking is
  dropped until the speaker gets louder or pauses for real.
- Repro: a 10.5 s continuous `say` sentence ("The long form seems to do
  the live transcription much faster…", via `sayClip`), with four echoes
  (30/70/130/210 ms at 0.5/0.35/0.25/0.15) and ±0.002 hiss, scaled ×0.1
  or ×0.3, goes through `UtteranceSegmenter(sampleRate: 16_000)` and only
  **the first 4.8 s comes out** as one utterance; the rest is lost. Scaled
  ×0.04 it gives nothing (below the 0.005 absolute minimum; may matter
  for quiet mics). Loud speech followed by the same sentence at ×0.06
  keeps 5.1 s of 20.9 s.
- The benchmark missed it: its `say` calls are short, with gaps between
  them. Add continuous long-talk clips (with room echo) to `wilco-bench`.

**Handoff for the fix:**

1. Write the failing test first: continuous room-echo speech (as in the
   repro) must come through nearly complete (e.g. ≥ 90% of the audio in
   utterances), and loud-then-quiet talking must not lock out. Put the
   `say`-based version in `WilcoTranscriptionTests` (it has `sayClip`); a
   synthetic version can go in `UtteranceSegmenterTests`.
2. Keep `noiseThatStartsMidSpeechStillEndsTheUtterance` and
   `steadyToneIsLearnedAsBackground` passing: rising hiss must still end
   an utterance. That test is why floor learning during speech exists.
3. Likely directions (decide from the tests): learn the floor only from
   frames well below the speech level, e.g. a low percentile over a longer
   window, or no learning while the level keeps varying like syllables;
   cap how far it can rise during speech; and stop learning from
   near-threshold frames between utterances so the floor can't lock at
   speech level.
4. Re-run `wilco-bench` (sweep and `--conversation`) to check final delay
   and missed calls, then have the user compare against long-form on
   their mic again. Whisper benefits from the same fix.

**Also seen:** with voice changes on, Parakeet gave 6–15 voice letters per
session and Whisper 7–12. If one person was talking (to confirm with the
user), the voice threshold is far too sensitive for a laptop mic, and each
false change splits a line. Turning voice changes off helped a little.
Look at this after the segmenter fix, since the segmenter's mid-sentence
cuts also feed the voice tracker.

### Next steps / where we left off

- **Fix the segmenter lock-out first** (handoff above).
- **Try it in the app:** speak on a Parakeet channel on "Fast, then
  corrected" and check the italics appear while talking and give way to
  the final line; switch to "Single pass" and check they stop.
- Watch for the Neural Engine stall on a show Mac. If it shows up in real
  use, find its cause (macOS speech services, power management) before
  relying on 32 Parakeet channels.
- **Whisper may drop its last line on stop** the same way (its flush also
  runs in the cancelled pump, `WhisperChannelTranscriber.swift`); check
  and apply the same fix.
- Review minors not done: a skipped preview waits a full 0.5 s before
  retrying; preview cost grows with call length (consider previewing
  only the last ~10 s of long calls); the greyed Latency picker on Whisper
  channels still reads "Fast, then corrected".
- Earlier items still open: real-show vocabulary check, voice letters on a
  real show, the voice threshold.

## 2026-11-16 — Segmenter no longer drops continuous speech

### Fixes

- **`UtteranceSegmenter` cut continuous talking mid-sentence and then
  ignored what followed** (the lock-out found in app testing above). The
  noise floor now rises only towards *steady* sound: over the last 1 s, the
  quietest 20 ms frame must be at least half the level of the loud frames
  (90th percentile). Hiss, hum and a tone measure about 0.94 and are still
  learned within a second or so. Talking never gets above 0.31, even with
  room echo filling the dips, so it is never learned. The same rule applies
  between utterances; the floor still falls freely there.
- Why the old rule failed: in a room the quietest frame in any second of
  speech is about a third of the median level, and speech had to be 4× the
  floor, so the threshold ended up above most of the speech. A longer
  window or a low percentile only narrowed this (3 s minimum still gave a
  threshold of 60–80% of the median).
- Known cost, accepted by the user: background that is not steady (music
  or crowd bleed, an off-mic conversation) is no longer learned mid-call
  and can hold a call open to the 20 s cut. Open mics are rare on the
  user's shows.

### Tests

- `ContinuousSpeechSegmenterTests` (`WILCO_ASR_TESTS`): a 14.9 s continuous
  `say` sentence with room echo and hiss must come through ≥ 90% at ×0.1
  and ×0.3 (was 67%, now whole), and loud talking followed by the same
  sentence at ×0.06 must too (was 33%).
- Two synthetic tests that run on CI: `continuousRoomSpeechIsNotLearnedAsBackground`
  (was cut at 1.96 s of 10 s) and `quietMutteringDoesNotRaiseTheFloor`.
- `noiseThatStartsMidSpeechStillEndsTheUtterance` and
  `steadyToneIsLearnedAsBackground` still pass unchanged.

### Numbers (`say` speech, M1 Max)

- Short calls are unaffected: at 32 channels, 0 missed, final p95 0.77 s
  (Parakeet), 0.76 s (with preview), 0.99 s (Whisper base); CPU 37% / 64% /
  30% of a core. Details in `docs/benchmarks/2026-11-16-m1-max-say-segmenter-fix.md`.
- Conversation, 32 channels: keeps up, 0 missed; merged turns 74 of 192
  against 63 before (cause likely the old rule shortening turn tails; not
  confirmed).

Tested, not verified.

### Next steps / where we left off

- **Compare against long-form on the built-in mic again** (Parakeet and
  Whisper): the missing stretches should be gone.
- **Add continuous long-talk clips with room echo to `wilco-bench`.** It
  still only has short calls, so it cannot see this class of bug.
- Quiet mics: speech under the 0.005 absolute minimum (the ×0.04 case)
  still gives nothing. Not addressed here.
- Then the voice threshold on a laptop mic (6–15 letters per session),
  now that mid-sentence cuts no longer feed the voice tracker.
- The other items from the previous section still stand (try previews in
  the app, the Neural Engine stall, Whisper's last line on stop, review
  minors).

## 2026-11-16 — Long-talk benchmark

### Tooling

- **`wilco-bench --long-talk`**: each channel plays written passages of
  13–17 s of unbroken talking, 3–8 s apart, made to sound like a mic in a
  room (four early echoes, hiss under the whole channel, a level per
  channel). About one talk in three starts loud and drops to a quiet voice
  halfway.
- **Words lost** is a new column for these runs: spoken words with nothing
  in the transcript where they belong. "Keeps up" also needs it at 10% or
  less. Before this, a talk cut off partway still counted as answered.
- The room sound moved from the segmenter test into `WilcoBench`
  (`RoomSound`), and the test uses the shared one. A new gated test checks
  that every benchmark voice comes through at the quiet level.
- Design and plan: `docs/superpowers/specs/2026-11-16-long-talk-benchmark-design.md`,
  `docs/superpowers/plans/2026-11-16-long-talk-benchmark.md`. How to run
  it: `BENCHMARK.md`, "Long talks".
- A long-talk run now waits 3 s after the last line before stopping. It
  used to stop once every talk had one line, which could cut off a talk's
  later lines. Found by the branch review.
- 11 new package tests.

### Numbers (`say` speech, M1 Max, 120 s runs)

Full tables: `docs/benchmarks/2026-11-16-m1-max-say-long-talk.md`.

- **The run catches the segmenter bug.** With the old noise-floor rule put
  back, 62–64% of words are lost at 8 channels and the run fails, with
  0/40 talks "missed".
- **Parakeet**: no words lost at 1, 8 and 32 channels, final p95 0.86 s at
  32, using 84% of a core.
- **Apple long-form**: keeps up at 32 channels, 0.2% of words lost.
- **Whisper base fails at 32 channels of long talking** (it keeps up at
  8), but that row's numbers contradict each other: 47 of 164 talks
  "missed" with only 4.6% of words gone. Likely cause, read from the code
  and not measured: a Whisper channel waits for the shared model before
  reading more audio; past 2 s the ring treats it as not listening and
  stops counting what it discards, and the channel's line times drift
  early.

Tested, not verified.

### Next steps / where we left off

- **Whisper under overload** (possibly an app bug too): confirm that a
  Whisper channel waiting on the model loses audio uncounted and stamps
  lines too early. Log each line's start and arrival in a 32-channel
  long-talk run. If so, read the ring while waiting, or count the loss.
- Whisper base loses 3.5% of words at 8 channels: the model ends two talks
  at "…keep dropping..." and leaves out the rest. Parakeet gets them
  whole, so it isn't the segmenter.
- **Decide:** words lost counts only missing words. An engine that writes
  wrong words over a lost stretch could still pass. Add a WER limit to
  long-talk runs?
- Add passages of 22–25 s so the segmenter's 20 s cut is exercised; the
  current ones are 13–17 s.
- Review minors not done: `--corpus --long-talk` doesn't check recording
  levels; the per-voice quiet test covers only the four default voices;
  the `--duration` guard is untested; a talk cut short shows a negative
  delay; the runner tests take 25 s.
- Add the preview engines to a long-talk run: first words currently come
  about 16 s after a talk starts without preview.
- **Compare against long-form on the built-in mic again** (still open from
  the segmenter fix).
- The other items from the previous sections still stand.

## 2026-11-20 — Hiding a channel from Combined; quiet channels' "." rows

Asked for during a show with real comms, to help troubleshooting.

### Features

- **Option- or Shift-click a channel chip to hide that one channel** in
  Combined or a group view. From "All channels" it turns every other chip
  on; more modifier-clicks hide more channels, and a modifier-click on a
  hidden chip shows it again. Once every channel is showing again it goes
  back to "All channels". Hiding the last channel still shown does
  nothing. A plain click works as before. The logic is
  `ChannelScope.chips(_:afterClicking:among:excluding:)`; the chips still
  store which channels are shown, so nothing new is saved.

### Fixes

- **Quiet channels no longer leave a "." row at the live end.** On a
  quiet channel the recogniser could report a lone "." as words in
  progress, which sat at the bottom of Combined, groups and Matrix
  columns. Text in progress with no letters or digits now counts as
  none (`TranscriptTimeline.hasWords`). Settled lines and the session
  file are unchanged.

Tested, and verified by the user in the app on live comms.

### Next steps / where we left off

- Hiding is stored as "show these channels", so a channel added during a
  session stays hidden until "All channels" is clicked. Store exclusions
  separately if that gets in the way.
- If "." lines still turn up as settled lines, filter them where lines
  settle too (and decide whether the session file keeps them).
- The report window's chips don't take modifier-clicks yet.
- The items from 2026-11-16 still stand.

## 2026-11-21 — Reports name their own show; colour dots; more symbols; capture shortcuts

### Fixes

- **Post-show reports now carry the show they were recorded with.** Every
  report used to take its title, channel names and colours from whichever
  show was open. Capture now keeps a copy of the show beside each
  transcript (`Transcripts/Session yyyy-MM-dd HHmm-ss.wilco`), written with
  the first line and updated when capture stops, so a rename during the
  session is kept. A silent session still leaves no files. Older sessions
  have no copy, so the report takes the saved or open show sharing the
  most channel IDs with the lines (the open show wins a tie), else the
  open show. This is a best guess: YE Phoenix and YE Dallas share 14
  channel IDs, so most of their older sessions tie and go to whichever is
  open. The `.jsonl` format is unchanged. Logic in `SessionShow`; the
  writer change is in `TranscriptWriter`.
- **Colour pickers show coloured dots.** Menu-style pickers become an
  `NSMenu`, which draws symbol images as templates and ignores
  `foregroundStyle`, so every dot was white. The dots are now non-template
  images (`ChannelTint.swatch`), in Automation settings and the channel
  inspector.
- **Starting capture twice quickly no longer starts two sessions.** A
  second press while the microphone check was pending is ignored.

### Features

- **More channel symbols, including a radio.** The Symbol picker has 27
  symbols in Comms, Departments and Stage sections, each with a name:
  Radio and Antenna (there is no walkie-talkie symbol), headset, phone,
  megaphone, pyro, haze, effects, curtain, crew, medical, security and
  more. The original seven are kept.
- **Capture menu with shortcuts:** Start Capture ⌘R, Stop Capture ⌘.
  Separate keys, so a double press can't stop a running show; each is
  greyed out when it doesn't apply. The Start/Stop button tooltips show
  them.

Tested (8 new tests for the show copy and matching); the user reports
everything looks good.

### Next steps / where we left off

- Older sessions that tie between shows follow whichever show is open. If
  that's a problem, add a Show menu to the report header that saves the
  choice as the session's copy.
- A channel added during capture is in the show copy only after capture
  stops; if the app quits mid-session, the copy is the show at the first
  line.
- Symbol names were checked on macOS 27; confirm they all draw on a
  macOS 15 Mac.
- The items from 2026-11-20 still stand.

## 2026-11-22 — Editable report markers, presets and Talkback

### Features

- **Report markers are now set per show** (Settings › Markers). The
  report's phrase lists used to be fixed in code; now each show carries
  its own `MarkerSettings` (`ShowDocument.markers`). `nil` means the
  built-in lists, so a show that was never edited saves no `markers` key
  and its file is unchanged. Labels can be renamed, added, deleted,
  turned off and dragged (first match in a category wins). Restore
  Defaults goes back to the built-ins. A report still uses the show its
  session was recorded with, so editing later doesn't change past
  reports.
- **Departments are a list, not a regex.** "X go" or "go X" for each
  name, plus the new **"LX 47 go" / "go sound 12"** form (any department
  with a cue number; "cue 47 go" is the same rule). The call said first in
  a line wins, then the longest name. Countdown and song start stay built
  in, each with an on/off switch.
- **Marker presets.** Save as Preset… / load / Manage Presets… in the
  Markers tab. Files are `Presets/Markers/‹UUID›.json`; names are unique
  ignoring case; loading copies the preset into the show (and asks first
  if the show has its own edits).
- **Built-in Concert, Corporate and Theatre presets**, read-only in code,
  under a "Built-in" heading. Each is the built-in lists plus changes;
  Concert adds talkback labels.
- **Talkback category** (purple) for band talkback mics: Monitor request,
  Soundcheck, Run it again, Problem. Empty in the built-in lists, so
  existing reports don't change.

### Fixes and checks

- Before swapping out the old rules, both detectors were run over all
  21,220 local session lines: no unexpected differences; 10 extra
  department calls found, all with a comma between the words ("go, pyro").
- Reports had slowed from 7.05 s to 15.9 s over all local sessions;
  lists are now split into words once per report and lines without "go"
  skip the department check (7.3 s).
- Report highlights and search now skip punctuation between words, so
  "Content, go" is marked.
- Each of the three features had a fresh code review; fixes from those
  are in.

Tested only (303 package tests, app builds). Not yet tried in the app.

### Tooling

- Specs and plans are also shown as local web pages in the browser.
- Three timing-sensitive segmenter tests failed once under load and
  passed on rerun; they look flaky.

### Next steps / where we left off

- Try Settings › Markers in the app: editing, dragging labels, the
  Presets menu, Save/Replace and Manage sheets, and the wider list column.
- Some built-in phrases may fire on ordinary chatter (Corporate "walk
  up", "keynote"; Concert "curfew", "headliner", "feedback", "take it
  from"; Theatre "act one/two"). Tighten them if reports get noisy.
- Deferred minors: department names must match words exactly
  ("followspot go" isn't caught); labels from a newer build are lost if an
  older one re-saves; undoing an edit still stores a full copy;
  a deleted preset says "couldn't be read"; redundant phrase pairs; a
  stale comment in `MarkerPresetsMenu.swift`.
- Cue markers from "Mark Cue Point" are still memory-only and don't reach
  reports.
- The items from 2026-11-21 still stand.

## 2026-11-22 (late) — Loading a configuration with unsaved changes

### Fixes

- **Loading a configuration did nothing when the show had unsaved
  changes.** The "Save changes before loading?" alert only showed while
  its window appeared active, but an open alert stops its window
  appearing active. So the alert closed itself as it opened, which also
  cleared the load request. Found by the user ("old configs are not
  loading"). Every saved show on disk still decoded; this was the prompt,
  not the files. Logging in a debug build confirmed it.
- New `WindowPrompt` in WilcoCore: the window that was active when the
  load was asked for shows the prompt and keeps it until it's answered.
  Three regression tests (306 package tests in all). Save As New's name
  sheet uses the same kind of check but stays open, so it's unchanged.

Verified: loading from the title menu with unsaved changes now asks,
and Don't Save loads the chosen show (user). Cancel, asking again and
Don't Save from the Configurations window were also checked by driving
the app through Accessibility.

### Next steps / where we left off

- The Configurations window's error alert (`lastMessage`) has the same
  "only while active" check, so an error raised there may close itself
  too. Check it and use `WindowPrompt` if so.
- Save in the unsaved-changes prompt for a "Not Saved" show still drops
  the requested load (deferred since 2026-11-12).
- The items from earlier today still stand: try Settings › Markers in the
  app and tighten noisy built-in phrases.

## 2026-11-22 — Post-show Review tab; long talk cut between words; alert titles

The user recorded a 6-hour show (2026-11-21, 16 Parakeet channels) to
gather data. Reading it back by hand turned up the problems below, and
the Review tab now finds the same things after every session.

What the session showed: transcription kept up all night (9 in 10 lines
appeared within 7.5 s, flat from 2 to 14 talking channels; the long
delays were long sentences); one channel carried 30% of the lines; the
"hear" highlight fired 12 times an hour on every channel; radios were
recognised worse than wired comms (median confidence 0.64–0.77 against
0.86–0.90); the channel "Tea Time" was heard as "T Time" every time; and
three channels barely spoke. A first read that half the lines were
chatter or lyrics was wrong: the band talkback had 9% fillers, like other
channels.

### Fixes

- **Long talk is cut between words.** At the 20 s limit an utterance used
  to end on whatever frame reached it, splitting words across two lines;
  46 of 56 capped lines in that session ran straight on. The cut now goes
  in the latest 100 ms of the last 3 s that is within 25% of the quietest,
  and the rest carries into the next utterance with nothing lost
  (`UtteranceSegmenter`).
- **Notification titles follow the rule's name.** A Notify action copied
  the rule's name when it was added, so a renamed rule kept alerting as
  "New Rule". New ones use the new `{rule}` placeholder; a title that
  expands to nothing shows the rule's name. Existing shows keep their
  title until edited (the Review offers the fix).

### Features

- **Review tab in the post-show report** (`Report/Review/` in WilcoCore,
  `ReviewView` in the app). Worked out from the `.jsonl` and show copy
  alone, so it works on every past session. Checks: show setup (leftover
  alert titles), unclear channels (relative to the session, since engines
  differ in confidence scale), common highlight or rule phrases, busy
  channel, lines cut at the limit, falling behind, quiet channels (one
  finding), and vocabulary suggestions: channel names heard wrong, then
  names heard often across earlier sessions of the same show.
- **One-click fixes** to the open show: mute a channel, keep a highlight
  off a channel, remove a phrase, add vocabulary, use the rule's name as
  the title. A fix shows Done once true, is disabled when the open show
  lacks what it names or isn't the session's show, and is off while
  capturing, because changing the show then restarts transcription on
  the channels it touches. Dismissals are kept per show.
- **Trend table:** this session beside up to four earlier sessions of the
  same show (lines, fillers, unclear, delay).
- Thresholds were tuned by running every saved session (41) through the
  review; four checks that cried wolf were changed (see the design doc's
  calls). Design and plan:
  `docs/superpowers/specs/2026-11-22-show-review-design.md`,
  `docs/superpowers/plans/2026-11-22-show-review.md`.

Tested: 55 new package tests, including a locally gated one that reviews
every saved session; 506 package tests in all; app builds without
warnings. A fresh whole-branch review found two important issues (a
stale review under a newly selected session; a guessed show getting
show checks and fixes), both fixed. Not yet verified in the app.

### Next steps / where we left off

- Try the Review tab in the app on the 2026-11-21 17:20 session. Check
  that switching sessions quickly never shows another session's cards,
  and that fixes are disabled during capture (no app tests cover these).
- Update the "Omar Notifications" rule's title in the real show (the
  Review offers it).
- Deferred from the review: the cut check counts lag of 19 s or more as
  cuts when transcription falls behind, and newer cuts can come up to 3 s
  early; a transcript not named "Session …" can see later sessions in
  its trend; the keep-off label doesn't say a channel added later starts
  excluded; a highlight listing only deleted channels stays on; history
  loads once per report window.
- Stage 2 of the design: a per-minute diagnostics file (input level,
  speech time, dropouts) so quiet channels can be told from low levels,
  and music/lyrics detection from audio. Stage 3: opt-in clips of
  unclear lines as a real-show test set for `wilco-bench`.

## 2026-11-23 — Default engine and language for new channels

### Features

- **Settings › Languages › New Channels** picks the engine (Long-form,
  Dictation, Whisper, Parakeet) and language a channel starts on when it
  is added. Saved with the show, beside the Whisper model, as two new
  optional fields, `defaultEngine` and `defaultLocaleIdentifier`. A show
  without them (every older file) still gets the platform default engine
  and US English; an engine name this build doesn't know falls back the
  same way. Existing channels keep their own settings.
- Choices that can't run are corrected rather than refused: an Apple
  engine default becomes Whisper before macOS 26, and Detect
  Automatically becomes US English on Apple's engines, which must be told
  the language.
- The language list follows the chosen engine. Apple's engines offer
  regional English (United Kingdom, Australia, Canada, Ireland, India, New
  Zealand, Singapore, South Africa; checked on this Mac); Whisper and
  Parakeet have one English. Asked by the user: UK English needs
  Long-form or Dictation.
- The engine pickers in the inspector and Settings share one set of names.

Tested: 4 new package tests (default engine and language used, explicit
engine still wins, round trip, older shows, unknown engine, detect on
Apple engines); 510 package tests in all; app builds without warnings.
Not yet verified in the app.

### Next steps / where we left off

- Try New Channels in the app: set Long-form and English (United
  Kingdom), add a channel, and check its inspector shows both.
- The Review tab items from 2026-11-22 still stand (quick session
  switching, fixes disabled during capture).
- Stage 2 of the show review design (per-minute diagnostics file) is
  planned in `docs/superpowers/plans/` and not started.

## 2026-11-23 — Sorting and a Created column in Configurations

### Features

- **Configurations window:** click Name, Channels, Created or Saved to
  sort by that column; click again to reverse. Names sort the Finder way
  ("Show 2" before "Show 10", case ignored). Rows that tie fall back to
  name order. It opens sorted by name, as before; the order isn't kept
  between openings.
- **Created column**, beside Saved. It shows the configuration file's
  creation date. Duplicate and Import count as new; Rename and Save
  Changes keep the date.

### Fixes

- Every save was resetting a configuration's creation date: an atomic
  write swaps in a new file. `ConfigurationStore.write` now puts the
  original creation date back after writing. The show format is
  unchanged.
- One-time fill-in at launch (`configurations.createdDatesBackfilled`):
  a configuration whose date had been reset gets the start of the first
  session recorded under the same show name, if that is earlier. It only
  moves dates earlier, and only sessions that have a show copy count. On
  this Mac only YE Phoenix 2026 has one (Nov 21 16:06). The configurations
  were backed up first to `~/Library/Application Support/Wilco-backups/`.

Tested: 6 new package tests (sorting by each column and ties, creation
date surviving a save, the fill-in); full package suite passes; app
builds. Not yet verified in the app.

### Next steps / where we left off

- Relaunch Wilco and check Configurations: Phoenix should show Created
  Nov 21 16:06 and Saved Nov 23 00:21; click each header to sort.
- Maybe keep the chosen sort order between openings of the window.
- Creation dates rely on the file system, so copying the folder to
  another Mac may reset them. Storing the date in the show would avoid
  that but is a format change; left for now.
- The New Channels and Review tab checks from earlier today still stand.

## 2026-11-23 — Session times in the zone they were recorded in

### Fixes

- **Times showed in the Mac's current zone.** Lines are stored in UTC,
  and the report converted them to wherever the Mac is now, so Saturday's
  Phoenix sessions read two hours late back on Eastern time. The report,
  HTML export, session list and Review trends now show times in the zone
  the session was recorded in.
- When that zone's offset differs from this Mac's, times carry its
  abbreviation ("5:23:06 PM MST") and the report header says so: "Times
  are Phoenix time (MST), when it was recorded: 2 h behind this Mac." When
  they agree, nothing changes on screen, and older HTML exports are
  byte-identical.
- The session list now groups by the day where the session was recorded.
  The Review's "earlier sessions" cut-off uses true start times.

### Format

- New optional `timeZone` on each `.jsonl` line (zone identifier), stamped
  by `TranscriptWriter` with the zone at capture start, the same zone used
  for the file name. Lines without it decode and write as before.
- Older sessions: `CaptureTimeZone` works out the offset from the file name
  against the lines (a quarter hour, within 2 min) and labels it "GMT-7",
  as the place can't be told. On this Mac: 9 sessions come out GMT-7
  (Phoenix, Nov 20–21), 1 GMT-6 (Nov 7; the file's creation date agrees),
  25 GMT-5. The Nov 6 file had lines added days after it was named, so it
  stays in this Mac's zone, unlabelled.

Tested: 12 new package tests (format compatibility, writer stamping, the
file-name fallback and its limits, label and note wording, HTML export,
history start times); full package suite passes; app builds. Not yet
verified in the app.

### Next steps / where we left off

- Open Post-Show on a Phoenix session: times should read as on the night
  with "MST"/"GMT-7" and the header note; an Eastern session should look
  as before.
- The live transcript still uses the Mac's zone. That only matters if the
  Mac changes zone mid-show.
- Peer lines (`PeerLine`) carry no zone yet; add one when peer sharing is
  rebuilt.

## 2026-11-23 — Global vocabulary as a summary row and chip editor

- **A long vocabulary filled the Languages tab.** Every term took its own
  form row, so the settings below it scrolled out of view. Settings →
  Languages and the Show inspector now show one row instead: the term count
  and the first few terms ("42 terms · Pyro, Fly 12, … and 38 more") with
  an Edit… button.
- **Edit… opens a sheet** that lays terms out as wrapping chips, each with
  ×. Add takes one term or several separated by commas; Paste List adds
  every line on the clipboard (a cue list from a script, say); Search
  filters the chips; Sort A–Z orders them. Blanks and case-insensitive
  duplicates are skipped.
- The inspector's "Show Vocabulary" is now "Global Vocabulary", the same
  name as Settings.
- Splitting, de-duplication, search and sort are in `WilcoCore`'s
  `TermList`; the sheet and row are `Wilco/Components/VocabularyEditor.swift`
  and reuse the existing `FlowLayout`. Stored data is unchanged, so older
  shows open as before.

Tested: 6 new package tests; full package suite passes; app builds with no
warnings. Verified: the user tried the sheet in the app.

### Next steps / where we left off

- Rule phrases, highlights, marker phrases and departments still use the
  inline one-row-per-term `TokenListEditor`. Switch any of them to the
  summary row and sheet if they grow long.
- The sheet could offer the Review's vocabulary suggestions as one-click
  chips.

## 2026-11-23 — Rename channels in the sidebar

- **Channels can be renamed in place in the sidebar**, as folders already
  could. Three ways in, for folders and channels alike: Rename in the
  context menu, Return on the selected row (as in Finder), or a
  double-click. Return or clicking away saves; Escape keeps the old name.
  Blank names are ignored and surrounding spaces trimmed.
- `ShowDocument.renameChannel(id:to:)` in `WilcoCore` does the trimming.
  The inline field moved out of `GroupRow` into a shared
  `Wilco/Sidebar/InlineNameField.swift`, and `AppModel.groupBeingRenamed`
  became `itemBeingRenamed`, so only one row edits at a time. Deleting a
  channel mid-rename ends the edit.

Tested: 1 new package test; full package suite passes; app builds with no
warnings. Verified: the user renamed channels in the app.

### Next steps / where we left off

- Combined, Matrix and Activity keep fixed names; Return and double-click
  do nothing on them.

## 2026-11-23 — Three-letter zone labels

- Zone labels are now letters wherever possible: older sessions known only
  by their offset read "MST", "CST", "EST" instead of "GMT-7", and zones
  the system spells as offsets on a US Mac get letters from its
  abbreviation table ("CET", "BST", "JST", "IST"). `ZoneAbbreviation`
  picks a zone with the same offset at that moment, preferring the same
  region, then common North American and European zones, then matching
  daylight saving. With no match (Sydney) it stays "GMT+11".
- An offset alone can't tell MST from PDT in summer; the label is the
  likelier one, and the times are right either way.

Tested: label cases for offsets, named zones in winter and summer; full
package suite passes; app builds. Not yet verified in the app.

## 2026-11-23 — Session diagnostics (show review stage 2)

Design: `docs/superpowers/specs/2026-11-22-session-diagnostics-design.md`.
Plan: `docs/superpowers/plans/2026-11-22-session-diagnostics.md`.

### Features

- **Diagnostics file per session.** Capture now writes
  `Session yyyy-MM-dd HHmm-ss.diagnostics` beside the transcript (JSON
  lines; not `.jsonl`, so the report doesn't list it as a session). One row
  per channel per minute: audio read, seconds of sound, RMS, peak, noise
  floor, clipped samples, dropped audio, utterances, speech seconds, cuts at
  the 20 s limit, model time, and the built-in sound classifier's speech,
  music and singing confidence for one 3 s clip. Format in `docs/SPEC.md`.
- **Where it's measured.** A `ChannelMeter` runs in each engine's read loop
  (`AudioSource.read(metering:)`), never in the capture callback. A
  `DiagnosticsRecorder` per session merges partial rows (start, stop,
  restart), waits up to 30 s past each minute for its classification, and
  appends. One `SoundClassifierQueue` for the app runs one clip at a time
  and drops clips when 64 are waiting.
- **Review checks that use it** (skipped for sessions without the file):
  - Quiet channels get a reason: no input, too faint, low level, not
    speech, not captured, or input fine and nobody talked.
  - Music channel (music or singing beats speech in ≥60% of ≥30 classified
    minutes): offers mute and keeping busy highlights off it.
  - Level too hot (clipping in ≥3 minutes and ≥5% of sound minutes).
  - Level low (median below −40 dBFS over ≥30 sound minutes); the unclear
    finding says when a low level may be why.
  - Lost audio (≥5 s dropped, or short or missing minutes while the
    channel was running), with clock times.
  - The 20 s cut count is exact where the engine reports it.
- **Benchmark:** `wilco-bench --diagnostics`. At 32 channels on Parakeet
  (M1 Max): kept up, no measurable CPU added, about +80 MB, 0 clips dropped,
  64 of 96 rows classified (`docs/benchmarks/2026-11-23-m1-max-diagnostics.md`).

### Fixes found in review

- Clipping was counted twice at block edges; speech/music minutes read the
  utterance field instead of the classifier; stopping could wait 30 s on a
  hung classification; a restart within 30 s of stopping lost the old
  session's show copy; one pop raised "level too hot"; a voice below the
  speech floor was called "input fine".

Tested: about 60 new package tests (every suite passes); app builds
without warnings; merged with the time-zone work from the same day. The
new checks' thresholds are **untuned guesses**: no saved session has a
diagnostics file yet. Not yet verified in the app.

### Next steps / where we left off

- Try it in the app: capture 2–3 minutes, check the `.diagnostics` file
  appears beside the `.jsonl`, isn't listed as a session, and the Review
  still opens.
- After the next real show, run the gated `reviewsSessionsWithDiagnostics`
  test and tune the thresholds; consider using the noise floor in the
  low-level check (hiss above −46 dBFS counts as sound today).
- Lost-audio clock times use the Mac's current zone, not the session's
  recorded zone (from today's time-zone work).
- Quitting while capturing loses the last 1–2 minutes of diagnostics rows
  (the session show copy has the same gap).
- Stage 3 (opt-in real-audio clips for `wilco-bench`), then a voice-change
  redesign: it over-splits on real comms (letters up to K for two people;
  one steady voice taken for another), tuned only on `say` voices.

## 2026-11-23 — Benchmarking other Neural Engine speech models

Decision: no changes to the app. Parakeet v3 stays the Parakeet model;
the candidates stay in `wilco-bench` only, for later re-runs.

### Research

FluidAudio 0.18.3, the version Wilco pins, already ships about 20 speech
models besides Parakeet v3. Seven were worth measuring against the
32-channel goal; the rest run on the GPU (LFM3-Audio, Phonon-2.5,
Nemotron Transcribe Lite), are far too slow (Cohere Transcribe, about 2×
real time) or target Chinese or Japanese.

Licences: Ultra, Phonon-2 and Unified are CC-BY-4.0 like v3. Parakeet EOU
is under the NVIDIA Open Model License. Nemotron's card contradicts itself
and Bark 3.0 Clean's card wasn't readable.

### Tooling

- `wilco-bench` gains the seven candidates (`CandidateEngines.swift`):
  `parakeet-ultra`, `phonon-2`, `bark-3-clean`, `parakeet-unified-offline`
  (one shared model each) and `nemotron-1120`, `parakeet-unified-1120`,
  `parakeet-eou-320` (streaming, one stream per channel).
- `StreamedUtteranceRecognizer` runs a streaming model behind the usual
  pause-cut utterances: each preview feeds only the new audio, the final
  line finishes and resets the stream. 5 new tests.
- Streaming models load from their folders directly, not through
  FluidAudio's download-and-recover path, which deletes the cache when a
  load fails and isn't safe with 32 channels loading at once.

### Results

Full tables: [`benchmarks/2026-11-23-m1-max-say-candidates.md`](benchmarks/2026-11-23-m1-max-say-candidates.md).

- **Parakeet v3 stays.** Over three seeds at 32 channels its word error
  rate averaged 3.9%; Ultra 4.6%, Unified 5.7–5.9%, Bark 3.0 Clean 6.8%.
  All of them keep up with the same delays.
- Phonon-2 (12%) and Parakeet EOU (13%, missed calls) are much less
  accurate. Nemotron loads a full model per channel and fails by 16
  channels (24 GB, dropped audio).
- Streaming doesn't beat v3's live preview for first words on short
  calls. On long talks at 32 channels, Unified streaming showed words
  sooner (1.8 s against 2.8 s) with half the CPU.

Tested: all on `say` speech only; nothing changed in the app.

### Next steps / where we left off

- Run the closest candidates (v3, Ultra, Unified) with `--corpus` on real
  comms recordings before treating the decision as final.
- If preview CPU at 32 long-talking channels becomes a problem, revisit
  Parakeet Unified streaming as the preview path for English shows.

## 2026-11-23 — Learning from shows, part 1: clips and labels

Show review stage 3. Design:
[`superpowers/specs/2026-11-23-real-show-clips-design.md`](superpowers/specs/2026-11-23-real-show-clips-design.md);
plan:
[`superpowers/plans/2026-11-23-learning-clips-part1.md`](superpowers/plans/2026-11-23-learning-clips-part1.md).
Decisions: labelling is automatic with no manual review, nothing leaves
the Mac, it lives in the app, and the goal is steering the models
(vocabulary, fix-ups), not retraining them.

### Features

- **Clips during capture** (Settings › Learning, off by default): each
  session keeps up to 100 unclear lines (below the channel's running
  25th-percentile confidence) and 20 exchanges (3–12 back-to-back lines),
  sampled across the whole night. They go in a `Session … .clips` folder
  beside the transcript: `clips.json`, `labels.json` and 16 kHz WAVs.
  Saving happens off the audio thread; a failed write stops that
  session's clips without growing memory.
- **Labelling after the show:** runs in the background 2 minutes after
  capture stops, at launch and every minute after; never during capture,
  and starting capture stops it between model calls. Voters are Parakeet
  Ultra, Apple Long-form and Whisper large-v3; a channel's own engine
  sits out. Two must agree on the words (three: any two). Two speaker
  models (the offline pipeline and Sortformer) group the voices; only
  groupings both agree on count.
- **Settings › Learning:** the switch, clip folder size, Delete All
  Clips, a row per voter and for voice grouping with download/remove,
  and labelling status.
- **Review:** an "Accuracy on the hardest lines" card per channel (10+
  scored clips) with last show's figure, and a "Hard-line errors" trend
  column.
- The text normaliser reads a lone "Q" before a number as "cue", so
  "Q 42" and "cue 42" agree.

### Tooling

- `wilco-bench --real-show` scores engines on the labelled clips, with a
  "live on the night" row and a voter-fairness line; `--transcripts`
  picks the sessions folder. Output is numbers only, never clip text.
- `WordErrorRate` moved into WilcoCore so the app and bench share it.

### Testing

Tested: 714 package tests pass and the app builds without warnings.
Built task by task with a review per task and a whole-branch review.
Not tested on real models: only Apple Long-form is installed here, so
the end-to-end labelling test got "not enough voters" on every clip;
the Ultra and Whisper-large voters have never run. Not verified in the
app.

### Next steps / where we left off

- Download Parakeet Ultra (and Sortformer for voices) in Settings ›
  Learning, then run `WILCO_ASR_TESTS=1 swift test` for the voter and
  labelling tests.
- Hand check in the app: switch Learning on, capture a few minutes,
  check the `.clips` folder appears, labelling starts 2 minutes after
  stopping and stops when capture starts.
- Part 2: names-to-add and fix-up cards in the Review, the show's
  `fixUps` field (applied before rules and highlights) and `heard`.
- Part 3: Check Clips.
- Known gaps: `--conversation` real-show runs can repeat an exchange
  near the end; before macOS 26 there's no third voter, so labelling
  needs both Ultra and Whisper large.

## 2026-11-24: Security review

### GitHub

- Turned on secret scanning with push protection, Dependabot alerts and
  security fixes, and private vulnerability reporting. Custom-pattern
  scanning and validity checks need a paid plan, so they stay off.
- A "Protect main" ruleset blocks force-pushes and deleting `main`.
  Ordinary pushes still work; sessions must merge or rebase, not force.
- Actions: only GitHub's own and verified actions may run, pinned to a
  commit SHA. `checkout` and `cache` in `ci.yml` are pinned.
- Added `.github/dependabot.yml` (Actions and SwiftPM weekly; FluidAudio
  stays pinned) and `SECURITY.md`.
- History checked: nothing from `reference/`, no keys or tokens, no
  naming of the reference app.

### App audit

Checked the capture callback, ring buffer, MIDI and HAL memory code,
OSC/webhook/HTML escaping, file loading and saving, logging (no transcript
text reaches the system log), data folder permissions, and the signed
build's entitlements. Two fixes:

- **Imported shows can't quietly send comms elsewhere.** Rules with a
  webhook, or OSC beyond the local network, come in turned off, with a
  message naming the rules and hosts (`OutboundRules`, spec §12.2).
- **Regex rules are bounded.** Long patterns and nested repeats such as
  `(a+)+` never match, and the rule editor warns; only the first 2,000
  characters of a line are searched; patterns are compiled once.
- **Hosts are read the way the system reads them.** An automated review
  caught that numeric forms such as `134744072` or `010.8.8.8` name public
  addresses but passed as local. Hosts are now parsed with `inet_aton` and
  `inet_pton`.
- Spec §12.1 sets the rules for the MCP server and peer sharing before
  they are built: no wildcard CORS, Host/Origin checks and a token for
  MCP; pairing and size limits for peers; both off by default.

### Testing

Tested: all package tests pass and the app builds without warnings. None
of the shows on this Mac use regex rules, so nothing existing changes.
Not verified in the app.

### Next steps / where we left off

- Hand check: import a show with a webhook rule and see the message and
  the rule turned off; type `(a+)+` as a regex phrase and see the warning.
- When release signing is set up: Release build (no `get-task-allow`),
  notarize, ship updates as zip or dmg, and move to Sparkle 2.11 once out.
- Build the MCP server and peer sharing to spec §12.1.


## 2026-11-24: Settings window keeps one size

### Fixes

- **Settings no longer resizes when switching tabs.** Each tab used to
  set its own size (540 to 860 wide, and some fit their height to their
  content), so the window jumped on every click. All tabs now share one
  size, 860×600, set once in `SettingsView.size`. The shorter forms (Look
  & Feel, Audio, Learning, Destinations) fill it and scroll if needed. A
  fixed size was chosen over animating the resize, which SwiftUI's
  `Settings` scene can't do without rebuilding the window in AppKit.

### Testing

The app builds. Verified: the user clicked through the tabs in the app.

### Next steps / where we left off

- If the short tabs look too sparse at 860 wide, keep their forms narrower
  and centred inside the same window.

## 2026-11-24: Security, deeper pass and guardrails

### Fixes

- **Files can't crash the app.** A transcript line with a negative or huge
  time offset crashed the report ("Index out of range"); a show with
  repeated IDs crashed sidebar editing; a diagnostics file with far-apart
  minutes could exhaust memory. Everything read from disk is now repaired
  as it is read (`FileRepair.swift`): numbers held within `FileLimits`,
  IDs made unique. Report columns are capped. `Int(safely:)` converts
  without trapping.
- **Regex time limit.** The nested-repeat check missed overlapping
  alternatives such as `(.|..)+!` (0.3 s on 30 characters, doubling from
  there). Searches are now stopped at 50 ms; a pattern that hits the
  limit is switched off until restart, reported in the Activity log and
  flagged in the rule editor.
- **Import** also turns off the show's sharing switches (`mcpEnabled`,
  `networkEnabled`, `mosEnabled`) and refuses files over 20 MB.
- **Webhooks** go through `WebhookSender`: no cookies, cache or stored
  credentials, redirects not followed (reported as errors), reply bodies
  not downloaded, methods from an allow-list.
- **HTML report** carries a content security policy allowing only its own
  script, by hash. The fixture has the new line.
- **Environment.** The app clears the variables its speech libraries
  would use to change the download host or attach a token.

### Checked, no change needed

On-device speech only (no server-capable API); dependencies contact only
huggingface.co and have no telemetry; SwiftUI shows interpolated text
literally (no Markdown links from names); WAV decoding and every delete
path are bounded.

### Guardrails

- `docs/SECURITY-MODEL.md`: what is trusted, the rules (§4), a checklist
  for new features (§5), release steps, known limits and findings so far.
- `CLAUDE.md` has a Security section pointing sessions at it.
- `SecurityGuardrailTests` reads the source and settings and fails when
  code listens on the network, makes HTTP calls outside `WebhookSender`,
  decodes outside `WilcoJSON`, logs, runs programs, uses a server-capable
  speech API, adds a dependency, entitlement, URL scheme or unpinned CI
  action, or tracks a private file. Both directions were tried: planted
  violations fail it.
- `HostileInputTests`: hand-written hostile files, seeded mutation of the
  fixtures (400 rounds each), and script-injection payloads through the
  HTML report.
- `reference/forbidden-words.txt` (untracked, this Mac only) lists the
  words the project must never contain; a guardrail checks every tracked
  file against it when the file is present.

### Testing

Tested: all package tests pass (756) and the app builds without
warnings. The webhook sender was also run against a local server: a
redirect's target received nothing and a 2 GB reply returned at once.
Repair changes nothing in the shows and transcripts on this Mac (5 shows,
21,220 lines). Not verified in the app.

### Next steps / where we left off

- Hand check: a webhook rule still fires to a local address; the HTML
  report still opens with tabs, chips and search working in Safari and
  Chrome (the security policy is new); import of a shared show.
- Optional: CodeQL for Swift in CI; pinning model files by hash.
- New features answer the checklist in `docs/SECURITY-MODEL.md` §5.

## 2026-11-24: Look & Feel trimmed, matrix column controls in the matrix

### Settings

- The Motion setting (Smooth, Snappy, Bouncy, Still) is gone. It added a
  choice nobody needed, and the sidebar (an `NSOutlineView`) never
  followed it even though the footer said it did. Animation is now one
  fixed eased style and still switches off when macOS Reduce Motion is
  on. The old `transcript.motion` preference is ignored.
- The Matrix Columns section is gone from Look & Feel; its buttons moved
  to the matrix.

### Matrix

- The toolbar now has Fit, Reset Column Widths, Reset Column Text Sizes
  and Expand All. Each reset greys out when there is nothing to reset
  (`MatrixLayout.hasCustomWidths`, `hasCustomFontSizes`,
  `hasCollapsedColumns`, with a test).
- Clicking a column's icon collapses it in one click. Collapse Column
  stays in the column's ••• menu.

### Testing

Tested: all package tests pass and the app builds without warnings.
Verified: the user tried the matrix resets, column resizing and the
one-click collapse in the app, and they work.

### Next steps / where we left off

- Text size shortcuts in the matrix: decided to leave as they are. The
  user likes how zoom works now; making ⌘+/⌘−/⌘0 also step or clear
  columns with their own size would be more complicated than it's worth.
  A column's own size stays in its ••• menu; Reset Column Text Sizes
  clears them all.

### Later the same day: voice changes off by default

- New channels now start with Mark voice changes off; the letters aren't
  accurate enough yet to be on by default. Channels already in a show
  keep whatever they have. Verified (2026-11-25): the user added a channel,
  saw it start off, and turned it on by hand.
- Learning: Keep audio clips used to do nothing when turned on mid-capture
  (read once at start; each channel's clip tap fixed when it started).
  Channels now ask a per-session `ClipSwitch` line by line, so it can be
  turned on or off during a capture. On: lines that start from then on are
  kept. Off: nothing more is kept; saved clips stay. One folder and
  manifest per session however often it's switched. The pane's "Using"
  size updates every few seconds (it showed Zero KB during a capture
  because it was only measured when the pane opened).
- Security checklist (§5): local preference only, not in the show file;
  nothing new read, sent or listened on; the size walk is off the main
  thread; switching off now stops keeping at once. `/security-review`
  couldn't run here (no `origin/HEAD`), so the checklist was done by hand.
- Tested: package tests (761) pass, including the switch and a running
  channel picking it up mid-capture; the app builds.
- Verified (2026-11-25): the user switched clips during a 105 s, 3-channel
  test capture. Its `.clips` folder shows clips on from the start, off from
  about 60 s and on again from about 79 s: 65 clips, each with its WAV and
  manifest entry, none dropped, one folder and manifest for the whole
  session.

## 2026-11-25: Post-show report tab order

### Features

- The report's tabs now run Channels, Chat log, Run of show, Review, and
  the report opens on Channels. The exported HTML page uses the same
  order (it has no Review tab) and also opens on Channels. The window's
  order comes from the order of `ReportModel.Tab`'s cases.
- Typing a search while on Channels still jumps to Chat log, since
  Channels has no lines to search.

### Testing

Tested: package tests pass and the app builds. The export fixture
(`report-v1.html`) was updated, including its Content-Security-Policy
script hash: the hash follows the inline script, which now starts on
`channels`. Verified: the user tried the new order and the Channels
start in the app.

### Next steps / where we left off

- Nothing open from this change.

## 2026-11-25: Ask to save on quit, Quit moves to ⌥⌘Q

- Settings has a new General tab with **Ask to save configuration changes
  when quitting** (`quit.asksToSaveConfiguration`, on by default). When the
  title shows Edited or Not Saved, quitting asks Save / Don't Save / Cancel.
  Not Saved offers Save As New…, which opens the name sheet and cancels the
  quit. The working copy autosaves either way, so Don't Save loses nothing:
  Wilco reopens with the changes, marked Edited. The rule is
  `ConfigurationRules.quitDecision` (tested); the prompt runs from an app
  delegate, so it covers the menu, the shortcut, the Dock and logging out.
- Quit Wilco is ⌥⌘Q; ⌘Q does nothing, so a slip can't end a show. The user
  asked for ⌘⇧Q, but that's macOS's Log Out, so they chose ⌥⌘Q instead.

Tested: all package tests pass and the app builds without warnings. Not
verified in the app.

### Next steps / where we left off

- Hand check: ⌥⌘Q quits and ⌘Q doesn't; edit a show and quit (asks), then
  Don't Save and relaunch (marked Edited); Save; turn the setting off (quits
  without asking); quit from the Dock.

## 2026-11-25: GPL-3.0 license

- Wilco is licensed GPL-3.0-or-later so every distributed version stays open
  source. `LICENSE` is the unmodified text from gnu.org, and the README has a
  License section. All dependencies (WhisperKit and Sparkle under MIT,
  FluidAudio and Swift Argument Parser under Apache-2.0) are compatible.
- Why GPL rather than MIT: the goal is that Wilco stays open forever, and
  only copyleft keeps forks open too. AGPL adds nothing for an app that runs
  on the user's own Mac.

### Next steps / where we left off

- Before taking outside contributions, decide whether to ask contributors to
  agree to a short contributor agreement, which keeps the option to ship on
  the Mac App Store (the GPL doesn't fit the store's terms).
- First release: tag `v0.3.0` and publish a signed, notarized GitHub
  pre-release.

## 2026-11-25: Settings redesign: sidebar split into This Show and This Mac

Settings was eight toolbar tabs that mixed show settings with this Mac's
preferences. To make it easier for people setting up their own shows, it
is now one window with a sidebar and a search field. Design:
`docs/superpowers/specs/2026-11-25-settings-redesign-design.md`; plan:
`docs/superpowers/plans/2026-11-25-settings-redesign.md`.

- **This Show**, numbered in setup order: 1 Audio, 2 Speech, 3
  Destinations, 4 Rules & Highlights (was Automation), 5 Markers. Each
  gets a green tick once it looks set up (`ShowSetupProgress`, tested):
  - Audio: a channel, and a device that is System Default or plugged in.
  - Speech: every channel's model installed. Parakeet needs its
    vocabulary model too.
  - Destinations: one switched on.
  - Rules & Highlights: one rule or highlight switched on.
  - Markers: never ticked.
- **This Mac**: General, Appearance (was Look & Feel), Speech Models,
  Learning.
- Languages is split. **Speech** has the show's choices: vocabulary,
  defaults for new channels, the Whisper model choice and voice tuning.
  **Speech Models** has every download, including the learning voters
  that were on Learning.
  - New: an Install button for the English long-form model learning uses.
    Before, it could only be installed through a channel.
  - That model is never listed as unused (`SpeechModelNeeds`, tested).
- Learning shows "N of 3 voters installed" and voice grouping on its own
  line, with a **Speech Models…** button.
- **Search** uses a fixed list of setting names (`SettingsIndex`,
  tested), never text from the show. It matches word starts, ignoring
  case and accents.
- Each page opens with a title and a one-line summary. Footers keep their
  first sentence, and the rest sits behind an ⓘ popover, with the wording
  unchanged.
- The window's minimum size is 1060×640 and it asks to be resizable. The
  selected page is kept in `settings.selectedPage`; an unknown value opens
  Audio.
- Messages that named old tabs now say Rules & Highlights or Speech
  Models. Nothing in `.wilco` files changed.

### Testing

Tested: all package tests pass (776, including 14 new ones) and the app
builds without warnings. A whole-branch review found five problems, all
fixed. The §5 security checklist was done by hand, since `/security-review`
doesn't run in worktrees here. Not verified in the app: this session
couldn't launch the app safely, so window resizing and the look haven't
been checked.

### Next steps / where we left off

- Hand check in the app:
  - Does the Settings window resize?
  - Do the ticks change as a show is set up?
  - Does search jump to the right page?
  - Do the ⓘ popovers open?
  - Does the header blend with the grouped form, in Dark mode too?
- Small follow-ups from review:
  - Speech could say when the chosen Whisper model isn't downloaded.
  - Empty search shows the system's "No Results" wording.
  - The window title reads "Settings" on every page.

## 2026-11-25: Settings sidebar: icons instead of numbers, no ticks

- At the user's request, the This Show pages in the Settings sidebar now
  carry icons like the This Mac pages: waveform, speech bubble, paper
  plane, bolt and flag. The step numbers and the green set-up ticks are
  gone. The pages stay in setup order.
- With the ticks gone, their logic went too: `ShowSetupProgress` and its
  tests, `SettingsPage.setupStep`, and the 3-second model check that fed
  the Speech tick (`SetupStatus`).
- A look closer to System Settings: each page's symbol sits white on a
  coloured rounded tile (`SettingsIcon`; the colours differ between
  neighbouring pages), search results carry the same tiles, the sidebar
  collapse button is gone and the sidebar can't be collapsed, and the
  page name moved to the title bar with the one-line summary under it.

### Testing

Tested: all package tests pass and the app builds without warnings.
Verified: the user tried the new sidebar look in the app and approved it.

Tooling: `~/Projects/Wilco/Worktrees` is a visible shortcut to
`.claude/worktrees` (ignored through `.git/info/exclude`), so a branch
can be built from `Worktrees/<name>/Wilco.xcodeproj` without showing
hidden files. Work stays on its branch while being tried; `/endsession`
lands it on `main` once approved.

### Next steps / where we left off

- Still to hand check from the Settings redesign: search jumping to the
  right page, the ⓘ popovers, and Dark mode.
- Small follow-ups: Speech could say when the chosen Whisper model isn't
  downloaded; empty search shows the system's "No Results" wording.

## 2026-11-25: Settings › General: show-day safety

General had one switch. At the user's request it now has six more, most of
them about keeping a show safe:

- **The Mac stays awake while capturing.** Nothing held off idle sleep or
  App Nap before, so a long quiet stretch could stall capture unnoticed.
  From Start to Stop Wilco now holds a system activity
  (`GeneralPreferences.captureActivity`). **Keep the display awake while
  capturing** (off by default) adds the screen and applies mid-show.
- **Ask before quitting while capturing** (on by default). Quitting
  mid-show used to end the session without a word. Cancel is the default
  button; the save question still follows.
- **Open Wilco at login** (`SMAppService`; macOS holds the state, and
  Settings offers Login Items when it needs approval) and **Start capture
  when Wilco opens** (off by default, noted in the Activity log), for a
  show Mac that has to come back after a power cut.
- **Keep sessions**: Forever (default), 30 Days, 90 Days or 1 Year. At
  launch, before labelling or capture can open anything, older sessions go
  to the Trash with every part (`.jsonl`, `.wilco`, `.diagnostics`,
  `.clips`). Only names that are exactly `Session yyyy-MM-dd HHmm-ss` count;
  paths are rebuilt from the name, never read from a file
  (`SessionRetention`). The page shows the Transcripts folder's session
  count and size, with Show in Finder.
- **Dismissed suggestions**: how many Review findings are hidden, and Show
  All Again. An open Review window reloads, so its next Dismiss can't write
  the old list back.
- Settings search knows all of them.

Security: answered the §5 checklist by hand in spec §12.4
(`/security-review` doesn't run here). `SessionRetention.swift` joined the
*Deleting files* guardrail list, with tests for hostile names, a symlink
pointing outside the folder, partial failures and a missing folder.

### Testing

Tested: 14 new tests; all package tests pass and the app builds without
warnings. Not yet tried in the app.

### Next steps / where we left off

- Try General in the app: keep-awake during a long capture (`pmset -g
  assertions` shows Wilco's hold), the quit check, and a relaunch with Keep
  sessions on 1 Year (the Activity log says what moved; the Trash has it).
- Open at login registers the exact build that turned it on; turn it off
  before switching between a worktree build and the main one.
- Still open from earlier: Settings search, the ⓘ popovers and Dark mode
  to hand check; check for updates automatically once Sparkle signing is
  set up.
