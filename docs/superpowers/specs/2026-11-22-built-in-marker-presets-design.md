# Built-in marker presets and a Talkback category

## Why

The user's shows range across theatre, corporate and concerts. They also
want Wilco to monitor band talkback microphones at concerts, not only comms.
Talkback is mostly requests to the monitor engineer and soundcheck chatter,
which fit none of the five report categories. Starter presets save writing
each kind of show's lists from scratch. Builds on
`2026-11-22-marker-presets-design.md`, which said no presets would ship. That
call is reversed here.

## Approaches

1. **A sixth category, Talkback (picked).** It gets its own filter chip and
   colour in the report.
2. Fit talkback into the existing categories, e.g. requests as Cue calls.
   No category code needed, but reports would mislabel what was said.

## Design

- **Talkback category.** Add `MarkerCategory.talkback`, the last case,
  titled "Talkback" and tinted `.purple`.
  - Chips only appear for categories that have markers, so older reports
    don't change.
  - Older builds drop talkback labels, as the lossy decoding already
    handles.
  - `.standard` (the built-in default set) gets no talkback labels, so
    unedited shows are unaffected. The Markers tab shows an empty Talkback
    section that you can add to.
- **Built-in presets.** `MarkerPreset.builtIn: [MarkerPreset]` holds Concert,
  Corporate and Theatre, each with a fixed UUID. They're defined in code, are
  read-only, and are never written to the presets folder.
  - They appear in the Presets menu under a "Built-in" heading, after your
    own presets.
  - Loading one works like loading any preset.
  - Manage Presets doesn't list them.
  - A user preset can share a built-in's name; both are listed, with yours
    first.
- **Each built-in is `.standard` with changes** (below). The standard lists
  stay as they are today.
- **A new match: "<department> <cue number> go"**, for example
  "LX 47 go", "sound 12 go" or "fly 3 go", labelled "LX 47 go". Theatre calls
  this way constantly, and neither the old nor the current rules catch it.
  - It applies to every show, so it widens unedited reports in the same way
    the department list already did.
  - Proposed; drop it if unwanted.

### Concert

- **Show phases.**
  - Add Changeover: "changeover", "change over", "turnaround".
  - Add Support set: "support act", "support set", "opening act", "opener is on".
  - Add Headliner: "headliner", "headline set".
  - Add Curfew: "curfew".
  - Remove Intermission and Curtain.
- **Departments.** Add "CO2", "haze", "strobes", "kabuki", "cryo", "lifts",
  "risers" and "IEM".
- **Talkback.**
  - **Monitor request:** "in my wedge", "in my ears", "in my in ears",
    "in my mix", "more me", "more vocal", "more vocals", "more guitar",
    "more keys", "more bass", "more kick", "more click", "less click",
    "turn me up", "bring me up", "can I get more", "can I have more",
    "too loud in".
  - **Soundcheck:** "check one two", "check check", "line check", "sound check",
    "soundcheck", "mic check", "one two one two".
  - **Run it again:** "from the top", "take it from", "one more time",
    "run it again", "again from".
  - **Problem:** "can't hear", "cant hear", "feeding back", "feedback",
    "no signal", "lost my ears", "pack died", "dead pack", "need batteries".

### Corporate

- **Show phases.**
  - Add Walk-up: "walk up music", "walk-up", "walk up".
  - Add VOG: "voice of god", "vog".
  - Add Keynote: "keynote".
  - Add Panel: "panel discussion", "panelists".
  - Add Q&A: "q and a", "q&a", "questions from the floor".
  - Add Awards: "and the winner is", "award goes to", "the winner is".
  - Add Break: "coffee break", "lunch break", "we're on a break", "back from break".
  - Remove Downbeat, Encore and Curtain.
- **Departments.** Add "playback", "slides", "VT", "camera", "cameras",
  "stream", "records" and "comfort monitors".
- **Songs.** Turn off the song-start pattern.

### Theatre

- **Show phases.**
  - Add Half: "the half", "this is your half", "half hour call".
  - Add Quarter: "the quarter", "this is your quarter".
  - Add Five: "this is your five", "five minute call".
  - Add Beginners: "beginners please", "beginners to the stage".
  - Add Places: "places please", "places everyone".
  - Add Clearance: "we have clearance", "front of house clearance".
  - Add Act up: "act one", "act two", "top of act".
- **Cue calls.** Add Warning: "warning lx", "warning sound", "warning fly",
  "warning automation".
- **Departments.** Add "automation", "flys", "rail", "revolve", "follow spots"
  and "SM".

## Tests

- Built-in presets have unique names and fixed IDs.
- Each built-in decodes after a round trip.
- `.standard` has no talkback labels.
- The `<department> <number> go` match.
- Talkback detection on a sample line.
- The report-v1 fixtures are unchanged.

## My calls

- The built-ins don't appear in Manage Presets, so they can't be renamed or
  deleted.
- The new match applies to all shows, not only the Theatre preset.
- Talkback is purple.
