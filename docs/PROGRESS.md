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
| Look & Feel | Text size, timecode, newest-first, follow live, motion style, matrix column widths/collapse/text size; Light, Dark or Match System. Imports existing preferences once. | built, awaiting user test |
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

### Next steps / where we left off

- **Try it in the app:** speak on a Parakeet channel on "Fast, then
  corrected" and check the italics appear while talking and give way to
  the final line; switch to "Single pass" and check they stop.
- Watch for the Neural Engine stall on a show Mac. If it shows up in real
  use, find its cause (macOS speech services, power management) before
  relying on 32 Parakeet channels.
- Earlier items still open: real-show vocabulary check, voice letters on a
  real show, the voice threshold.
