# Learning from real shows: clips, labels and fixes

Status: approved 2026-11-23. Stage 3 of
`2026-11-22-show-review-design.md`.

## Why

The user wants Wilco to make fewer mistakes over time from real show
audio: "over time with real world audio, we can direct the models to make
less mistakes", built into the app.

Two things stand in the way today:

- Wilco can't tell what it got wrong. Every benchmark plays `say` speech,
  far cleaner than real comms, and a transcript alone doesn't say which
  words were wrong. The worst errors are names and callsigns: on
  2026-11-21 the channel "Tea Time" was heard as "T Time" all 11 times.
- Voice changes over-split on real shows (two people reached letter K)
  and were tuned only on `say` voices.

**What "direct the models" means here** (agreed 2026-11-23): steering,
not retraining. The speech models stay fixed. Wilco gets better by giving
them the right vocabulary, fixing words they keep getting wrong, and
picking settings that suit the show. Retraining a model on show audio
needs many hours of labelled audio, a training setup outside the app and
a conversion back for the Neural Engine, and it can make the model worse
elsewhere. It's out of scope; it may be worth a one-off experiment once
clips add up to 10+ hours.

The user's constraints:

- **No person needed.** They would review clips the morning after a show
  only rarely ("next to never"). Everything must work without them.
  Reviewing is an optional extra that makes the answers better.
- **Everything stays on the Mac.** No audio and no transcript text goes to
  any outside service, Claude included. (They turned down having Claude
  settle the clips the models disagree on.)
- **Built into the app**, not a developer tool to run.

## Goals

- Opt-in: each session keeps short clips of the lines that matter for
  testing (unclear lines, and exchanges for voice changes).
- After the show, the app labels the clips by itself, in the background:
  the words by agreement between slower, stronger models, and the voices
  by grouping the whole session at once.
- The Review turns labels into one-click fixes: names to add to the
  vocabulary, and show-wide fix-ups for words still misheard with them.
- The Review shows whether it's working: how often the live engine got
  words wrong, per channel, across sessions of the same show.
- An optional, short **Check Clips** list shows only clips the models
  couldn't settle that hold a name. The user's answer beats the models'.
- `wilco-bench --real-show` scores engines and settings on the labelled
  clips, for choosing engines and for stage 4 (voice changes).

## Non-goals

- No retraining or fine-tuning of any model.
- No cloud and no Claude in the loop.
- No continuous recording of channels; only the audio of kept lines.
- No changes made without a click (as in stage 1).
- No engine or voice-threshold suggestions in the app yet. Those need
  engines run against each other on the clips in real time, which is the
  bench's job. Stage 4 builds voice-change fixes on this stage's data.
- No session deletion feature (none exists today; see Deleting).

## Anti-goals

- **Slowing a show.** Labelling never runs during capture, and stops
  within a second or two when capture starts. Nothing new touches the
  capture callback.
- **Fixes that make things worse.** A fix-up that turns right words into
  wrong ones is worse than none. Fix-ups are offered only on repeated,
  agreed evidence, show what they'd change, and are easy to remove.
- **Answers that look trustworthy but aren't.** A clip the models disagree
  on is left out, not guessed.
- **An answer key that flatters one engine.** The live engine (Parakeet v3
  on the user's shows) is never one of the voters.
- **Nagging.** Check Clips is never a prompt or a badge that demands
  attention; it's a quiet card in the Review that can be ignored.

## Constraints

- Deployment target macOS 15; Apple's speech engines need macOS 26. CI
  runs Xcode 26.6.
- Existing `.jsonl`, `.wilco`, `.diagnostics`, Whisper and Parakeet model
  folders and preferences keep opening. New show fields need defaults.
- The session lists and Review ignore the new sidecar folder, as they
  ignore `.diagnostics`.
- Real people's voices: clips and labels are never committed, never quoted
  in docs, commit messages or bench reports.
- Strings from speech are untrusted. Fix-up text is user-confirmed but
  still goes through the same sanitising as any transcript text.
- `docs/SPEC.md` is the source of truth for file formats; it gains the
  `.clips` folder and the show's new `fixUps` field.

## Approaches

**A. Everything on the Mac, built into the app (chosen).** The app keeps
clips, labels them after the show with local models, and offers fixes in
the Review. Weakness: a mistake every model makes still gets into the
answers; the optional Check Clips list is where the user can catch those.

**A′. The same, but labelling in `wilco-bench`.** Smaller to build, no
model downloads in the app. Rejected: the user wants it built in, and a
loop that needs a developer command won't run after every show.

**B. A plus Claude settling disputed clips.** Better on names, but
transcript text would go to Anthropic. Rejected by the user.

**Hand correction of every clip** (the stage 1 draft). Rejected: the user
would almost never do it, so clips would never get labelled.

## Design

### Build order

The stage is large, so it's built and merged in three parts, each useful
alone:

1. **Clips and labels.** Keep clips; label them in the app; per-channel
   accuracy and its trend in the Review. `wilco-bench --real-show`.
2. **Fixes.** Vocabulary cards from labels; show-wide fix-ups.
3. **Check Clips.** The optional list.

### 1. Keeping clips

**Switch.** A new **Learning** section in Settings (or tab; builder's
call) with "Keep audio clips to learn from shows", off by default. It's an
app preference in `UserDefaults`, not part of the show: it's about
gathering data, not how a show runs. Below it: "Clips stay on this Mac,
about 30–50 MB a show", the size used, and **Delete All Clips**. A change
during capture takes effect at the next session.

**Where the audio comes from.** Every engine hands each final line's
16 kHz mono audio to `deliverFinalLine(... audio:)` in
`VoiceAnnotator.swift`, off the real-time thread. The clip keeper hooks in
there, which covers all four engines with one change. On the Apple
engines that audio comes from `AudioHistory`, which today exists only with
voice changes on; it must also exist when clips are on.

**What's kept.**

- *Unclear lines:* confidence in the lowest part of its own channel's
  confidences so far, so radio and wired channels are each judged on
  their own scale. Starting point: below the channel's running 25th
  percentile once it has 20 lines; below 0.75 before that. Lines with no
  confidence count as unclear.
- *Exchanges:* a run of 3 or more back-to-back final lines on one channel,
  each starting within 10 s of the last one's end; up to 12 lines. Every
  line of the run is kept, in order.
- A line that is both counts once. Lines under 0.5 s, or cut at the 20 s
  cap, are skipped.

**Caps and spread.** At most 100 unclear lines and 20 exchanges per
session. Each kind keeps a uniform sample over the whole session
(reservoir sampling), so a 6-hour show isn't all doors and first hour. A
clip that loses its slot is deleted at once. Exchanges are sampled whole.

**Linking a clip to its transcript line.** The engine's `lineID` is not
the `.jsonl` line's `id` (`TranscriptTimeline` makes a new one), and the
voice letter is worked out after `deliverFinalLine`, sometimes splitting
one utterance into two lines. So a clip has its own ID and records its
channel, start (`sessionOffset`) and length. The live text and voice
letters are read from the `.jsonl` later: the lines on that channel whose
`sessionOffset` falls inside the clip. Clips need no change to the
transcript format (fix-ups add one optional field; see section 3).

**Files.**

```
Session 2026-11-21 1720-04.jsonl
Session 2026-11-21 1720-04.diagnostics
Session 2026-11-21 1720-04.clips/
    clips.json          what was kept and why
    labels.json         written by labelling
    <clip-id>.wav       16 kHz mono 16-bit PCM, one per kept line
```

`clips.json` (rewritten atomically, at most every few seconds, and when
capture stops):

```json
{
  "version": 1,
  "clips": [
    { "id": "<uuid>", "channel": "<uuid>", "kind": "unclear",
      "sessionOffset": 812.4, "duration": 3.1, "confidence": 0.58,
      "engine": "parakeet", "exchange": null }
  ],
  "dropped": 0
}
```

**Writing.** An actor off the transcription path decides and writes. If
more than about 32 clips are waiting, new ones are dropped and counted,
never blocking transcription.

### 2. Labelling in the app

**Models.** Three voters from different families, none of them the live
engine:

| Voter | Install | Vocabulary given as |
|---|---|---|
| Parakeet Ultra | new download in the Learning section, managed like v3 (`AsrModels` `.ultra`) | vocabulary bias |
| Apple Long-form (macOS 26+) | Languages settings, as today | contextual strings |
| Whisper large-v3 (optional, about 3 GB) | Whisper models, as today | prompt |

Before macOS 26, Parakeet Unified offline replaces Apple Long-form.
Labelling needs at least two voters installed; the Learning section lists
what's installed and offers the downloads. With two voters both must
agree; with three, any two. If the live engine on a channel is one of the
voters (say Ultra or Whisper large on that channel), that voter sits out
for that channel's clips and the other two must agree.

**When it runs.** In the background, at low priority:
- 2 minutes after capture stops;
- at launch, for sessions with clips and no finished labels;
- never while capturing. Starting capture cancels it; work already done
  is saved per clip, so it picks up where it stopped.

A 100-clip session takes a few minutes. Progress shows as a small line in
the Learning section and on the session's Review ("Labelling clips: 40 of
120"). [builder's call on exact placement]

**Words.** Each clip is transcribed whole by each voter, with the show's
vocabulary (from the session's show copy, else the best-matching show, as
the Review does). Texts are compared after normalising: lower case, no
punctuation, numbers and spelled numbers made the same. A clip is
**agreed** when the required voters match; the answer is the matching
text (the voters' casing kept for names). Otherwise it's **disputed**.
Starting point; the builder may loosen "match" to a word error rate of 10%
or less if exact agreement leaves too few clips.

**Voices.** For each channel, its clips are joined in session order with
1 s of silence between, and two FluidAudio offline diarizers run over the
result: the offline pipeline (`OfflineDiarizerManager`: WeSpeaker and VBx
over the whole recording) and offline Sortformer (a different model
family). A clip's voice is **agreed** when both group it with the same
other clips. Voices are per channel. Live letters aren't used as input.
This is weaker than the words: both can make the same mistake, and the
live tracker shares WeSpeaker with the first. Sortformer is a further
download, in the Learning section. Voice labels are used only by the bench
and stage 4 in this stage.

**`labels.json`:**

```json
{
  "version": 1,
  "voters": { "parakeet-ultra": "…", "apple-longform": "26.2" },
  "clips": [
    { "clip": "<uuid>", "words": "agreed", "text": "Standby Tea Time cue five",
      "candidates": { "parakeet-ultra": "…", "apple-longform": "…" },
      "voice": "agreed", "speaker": 2,
      "checked": null }
  ],
  "finished": true
}
```

`words` is `agreed`, `disputed` or `checked` (the user's answer, in
`checked`, which overrides). If the voter list changes (a new download),
clips are relabelled except checked ones.

### 3. What the Review shows

All new checks go in `ShowReview` in WilcoCore and skip sessions without
labels, as the diagnostics checks skip sessions without diagnostics.

**Accuracy per channel (info).** For each channel with at least 10 agreed
or checked clips: the share of words the live engine got wrong (word
error rate of the live text against the answer), and the same figure for
earlier sessions of the show, in the trends table. It's measured on the
kept clips, which lean towards unclear lines, so it reads as "on its
hardest lines", not overall accuracy. This is how the user sees the app
getting better.

**Names to add (fix: add vocabulary).** A word or phrase in an agreed or
checked answer that the live text got wrong, and that looks like a name
(capitalised away from the start of the line, or a channel, group or rule
name in the show), seen wrong on at least 3 clips across this and earlier
sessions of the show, and not already in the vocabulary. It merges with
stage 1's vocabulary suggestions: one card, with the evidence counts.
Uses the existing `addVocabulary` fix.

**Fix-ups (fix: add a fix-up).** When a name is already in the vocabulary
and the live engine still gets it wrong the same way on at least 3 clips
across sessions ("T Time" for "Tea Time"), the Review offers a show-wide
fix-up. The card shows the count, two sample lines before and after, and
how many of this session's lines the fix-up would have changed. It's
offered only when the wrong form never appears in an agreed answer
elsewhere (so it isn't a real phrase on this show).

**Fix-ups in the show.** `ShowDocument` gains `fixUps: [FixUp]` (default
empty, so older shows open unchanged). A `FixUp` is a pair of texts: what
to look for and what to write instead. They are applied to each final
line's text in the app before it is shown, saved, matched against rules and
highlights, or sent out. They match whole words, ignore case, and keep the
replacement's casing. Settings lists them under the vocabulary with a
remove button; the list is editable by hand too. Applying to final lines
only (not live previews) keeps it simple; previews may show the wrong form
briefly. [builder's call: whether previews get them too]

When a fix-up changes a line, the `.jsonl` line keeps what the engine
heard in a new optional field, `heard` (written only when it differs, so
other lines are unchanged and older files still open). The Review uses it
to show what each fix-up changed, and the accuracy and fix-up checks
compare against what was heard, so a fix-up can't hide its own mistakes.

The new `ShowFix` cases are `addFixUp(FixUp)`, with
`ShowDocument.applying(_:)` tested like the others.

### 4. Check Clips (optional)

A card in the Review, only when there are clips to check: "6 clips the
models couldn't settle, with names in them. About 2 minutes." Opening it
shows one clip at a time:

```
 ┌───────────────────────────────────────────────────┐
 │  Check Clips                             2 of 6   │
 │  Channel Stage Manager · 21:14                    │
 │                                                   │
 │   ▶  Play (3.2 s)                                 │
 │                                                   │
 │   ○ standby t time cue five       Parakeet Ultra  │
 │   ○ standby tea time cue five     Apple Long-form │
 │   ┌─────────────────────────────────────────────┐ │
 │   │ standby Tea Time cue five                   │ │
 │   └─────────────────────────────────────────────┘ │
 │                                                   │
 │   Skip                     Not speech    Save ⏎   │
 └───────────────────────────────────────────────────┘
```

- Only disputed clips whose candidates hold something name-like, at most
  15 per session, names seen most often first.
- Space plays, picking a candidate fills the field, Return saves and goes
  to the next. Skip leaves it disputed. "Not speech" drops it.
- Saved answers go into `labels.json` as `checked` and feed the Names and
  Fix-ups checks at once.
- Nothing nags: no badge, no prompt; the card just sits in the Review.

### 5. `wilco-bench --real-show`

Reads the clips and labels the app wrote (default: the app's transcripts
folder), using agreed and checked clips only:

- Default and `--long-talk`: clips played as calls into 1–32 channels in
  real time, as `--corpus` does. Word error rate, delay, CPU.
- `--conversation`: each exchange played in order on one channel (gaps
  capped at 3 s), with voice changes scored against agreed voices.
- A **Live** row: what the app heard on the night, against the same
  answers.
- Engines that are also voters are marked, and also scored on the clips
  where they weren't one of the agreeing voters.
- **Numbers only** in the report: no clip text, candidate text or channel
  names, so a Claude session can run it without show text leaving the
  Mac. Counts of agreed, disputed, checked and dropped clips at the top.

### Deleting

Clips go with their session. A `.clips` folder with no `.jsonl` beside it
is ignored and removed by **Delete All Clips**, which removes every
`.clips` folder (labels included). Wilco has no in-app session delete;
if one is added, it must remove `.clips` too.

## Testing

- Package (with fakes for models): selection rules, reservoir spread and
  file replacement, `clips.json`/`labels.json` round trips, dropping under
  back-pressure, linking clips to `.jsonl` lines, normalising and the
  agreement rules (two voters, three, live engine sitting out), voice
  agreement from two given diarizer results, resuming labelling, accuracy
  per channel, name detection, fix-up offering (and not offering when the
  wrong form is a real phrase), applying fix-ups (whole words, casing,
  sanitising), `ShowDocument` decoding without `fixUps`, the new
  `ShowFix`, Check Clips selection.
- Gated (`WILCO_ASR_TESTS`): label a small `say`-made `.clips` folder end
  to end with real voters.
- App: labelling cancels when capture starts (no app test covers this
  today; check by hand).
- After the next real show: run the gated review over sessions with
  clips, tune the thresholds, and run `--real-show` at 1 and 16 channels.

## Calls made (check these)

- Steering, not retraining (agreed with the user).
- Labelling in the app, in the background after capture, never during it
  (the user asked for built in; the timing is my call).
- The live engine is never a voter, so the answers don't flatter it.
- Two voters must agree; disputes are left out, not guessed.
- Fix-ups apply to final lines before rules and highlights (the user agreed
  2026-11-23, knowing a fix-up can then trigger OSC/MIDI), so rules see
  the fixed text.
- Engine and voice-threshold suggestions stay in the bench for now.
- Switch is an app preference; caps 100 unclear + 20 exchanges.
- Clips matched to transcript lines by channel and time. The `.jsonl`
  gains only one optional field, `heard`, on lines a fix-up changed.
- Built and merged in three parts.

## Left to the builder

Exact thresholds (percentile, exchange gap and length, agreement
tolerance, name detection, fix-up evidence), the Learning section's place
and wording, file and type names, the normaliser's number rules, how
exchange gaps are rebuilt in `--conversation`, whether previews get
fix-ups, progress placement.
