# Show review: learn from each session

Status: approved 2026-11-22. The user picked approach A (Review tab); stage 1
is built first.

## Why

The user recorded a full 6-hour session on 2026-11-21 to gather data and
asked what we can learn from it for the next show, and whether the app
could get better on its own from past shows. Reading that session by hand
found real problems (one channel carried 30% of the lines, a common
highlight word fired 12 times an hour, sentences cut
mid-word at the 20 s limit, radio channels recognised worse, a
notification titled "New Rule"). None of that is visible in the app today.
The goal is that the app finds these itself after every show and offers
the fix, so each show is set up a little better than the last.

## What last night showed (2026-11-21, 16 channels, Parakeet)

- Kept up all night: delay did not grow with load (p90 7–8 s whether 2 or
  14 channels were talking); short calls settled about 1.7 s after the
  start. Long delays are only long sentences.
- The band talkback was by far the busiest channel (1,403 lines, 30% of
  the session). It is real band–monitor talk: 9% fillers, like the other
  channels. The artist vocal mic (855 lines) was mostly lyrics.
- The "hear" highlight fired 76 times (12 an hour), at about the same
  rate on every channel: the word is simply too common.
- 56 lines hit the 20 s cap and 46 continued straight into the next line,
  splitting words. Fixed 2026-11-22 (cut between words).
- Radio channels median confidence 0.64–0.77 vs 0.86–0.90 wired; names
  and callsigns fail most: the channel "Tea Time" was heard as "T Time"
  all 11 times it was said.
- The "Omar" rule was accurate (one low-confidence miss), but its
  notification title was the literal "New Rule". Fixed 2026-11-22 (`{rule}`).
- Three channels were nearly silent all show; the transcript can't say
  whether nobody talked or the level was low.

## Goals

- After a session, a **Review** that lists what went wrong, per channel
  and per rule, with the evidence (numbers and a few example lines).
- Each finding offers a **one-click fix** to the show where there is one
  (mute a channel, keep a highlight off a channel, add words to the
  vocabulary, fix a notification title). Nothing changes without a click.
- **Name and callsign suggestions** gathered from past sessions, to feed
  the show vocabulary (which Parakeet already biases towards).
- **Trends** across sessions of the same show, so a fix can be seen to
  work ("band talkback filler 30% → 8% since muting fillers").

## Non-goals

- No model training, no cloud, no data leaves the Mac.
- No changes made automatically, and nothing during a show.
- No new per-channel knobs where a show-wide setting does
  (see the preference for show-wide settings).

## Anti-goals

- A review that cries wolf. A check that's wrong more often than right is
  worse than none; each check needs a threshold tuned on real sessions.
- Anything that touches the capture callback or slows transcription.

## Approaches

**A. Review tab in the report window (recommended).** A fourth tab next to
Run of show / Log / Channels. The engine is a pure function in WilcoCore
(`ShowReview`), the tab shows its findings and applies fixes to the show.
Fits where the user already looks after a show, reuses report loading and
the show copy saved with each session, and the same engine can drive a
command-line tool later for free.

**B. Command-line `wilco-review` writing an HTML page**, like `wilco-bench`.
Quickest to build and good for development analysis, but the user has to
run it and it can't apply fixes.

**C. Live coach during capture.** Catches some problems while they can
still be fixed (a dead channel at doors), but most checks need hours of
data, and alerts mid-show are a distraction. Possible later for one or two
checks only ("channel silent 30 min while others are busy").

## Design (approach A)

### Stage 1: Review from what's already saved

Input: the session's `.jsonl` lines, its show copy (or the matched show),
and summaries of earlier sessions of the same show.

`ShowReview.make(lines:show:history:) -> ShowReview` returns a session
summary and a list of `Finding { key, severity, title, detail, evidence:
[line IDs], fixes: [ShowFix] }`. `key` is stable (check + channel/rule
ID) so a dismissed finding stays dismissed.

Checks (thresholds are starting points, tuned against the 41 saved
sessions in a locally gated test):

| Check | Signal | Fix offered |
|---|---|---|
| Busy channel | ≥300 lines and ≥25% of the session's lines | Keep busy highlights off it; mute channel |
| Unclear channel | median confidence < 0.8 with ≥30 lines | Name suggestions from that channel; check input |
| Quiet channel | < 4 lines/hour while the session is busy | None (info: check patch/level) |
| Cut long talk | lines that settled ≥19 s after they started | None (info; should fall after the fix) |
| Falling behind | delay p90 rising across the session | None (info: fewer channels or lighter profile) |
| Common phrase | a highlight or rule phrase hitting ≥10 times an hour | Remove the phrase (highlights) |
| Name suggestions | capitalised words/pairs seen ≥3 times (this and past sessions), not in vocabulary; near-misses of vocabulary or channel names ("T Time" ~ "Tea Time") | Add to show vocabulary |
| Show setup | notification title that's a plain leftover ("New Rule") | Set title to `{rule}` |

Delay per line is `timestamp − (session start + sessionOffset)`; session
start is the minimum of `timestamp − sessionOffset` (whole-second
timestamps, so ±1 s).

`ShowFix` is an enum (`muteChannel`, `keepHighlight(_:offChannel:)`,
`removePhrase(_:fromHighlight:)`, `addVocabulary([String])`,
`useRuleNameAsTitle(rule:)`) with a pure, tested
`ShowDocument.applying(_:)`. Keeping a highlight off a channel sets its
`channelIDs` to every other channel (empty means all channels), so a
channel added later starts excluded; the fix says so.

Shows have no ID, so a fix is offered against the **open show** (the
app's `document`) when every channel, rule or highlight it names exists
there; otherwise its button is disabled with "Open the show this session
was recorded with". A fix whose result is already true (channel already
muted, word already in the vocabulary) shows as done. Applying sets
`app.document`, which already saves and updates live capture.
[builder's call]

Dismissed finding keys are kept in `UserDefaults` (`review.dismissed`), not
in the show, so dismissing works whichever show is open and doesn't mark
the show edited. [builder's call; the draft said the show file]

Trends: a table of the last five sessions of the same show, newest first:
lines, filler share, unclear share, delay p90. "Same show" means the same
show name (session copy, else best match), so YE Phoenix and YE Dallas
stay apart even though they share channel IDs. Summaries are worked out
in the background when the Review tab first opens and kept in memory; no
new files. The same pass gathers name counts for vocabulary suggestions.
[builder's call]

### Stage 2: diagnostics file

A sidecar `Session yyyy-MM-dd HHmm-ss.diagnostics.jsonl`, one row per
channel per minute: input level (mean/peak dBFS), speech seconds,
utterances, cap cuts, ring overruns, transcription time. Written from the
transcriber pump (not the capture callback). The `.jsonl` format is
unchanged; checks that need it skip older sessions. This answers "silent
because nobody talked, or because the level was low?"

### Stage 3: real-audio test set (opt-in)

Off by default. Keeps short clips of low-confidence lines (capped per
session) beside the session, deleted with it. Corrections typed in the
report become ground truth, and `wilco-bench` gains a "real show" set so
models and settings are scored on real comms audio.

## Calls made while building (check these)

- No "sounds like music" or "chatter" check in stage 1. On the 2026-11-21
  session, text signals didn't separate those channels from crew comms:
  the vocal mic had 6% crew-call words and lasers 8%; the band talkback
  had 9% fillers and safety 10%. A check built on them would cry wolf.
  Music detection moves to stage 2, where the audio is available.

- Fix availability by target IDs in the open show, not by show identity.
- Dismissals in `UserDefaults`.
- "Same show" by name.
- Stage 2 (diagnostics) and 3 (audio clips) are separate designs later.

## Left to the builder

Filler and comms word lists, exact thresholds after tuning, the tab's
layout details, sample-line selection (shortest representative lines).
