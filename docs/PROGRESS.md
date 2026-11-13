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
