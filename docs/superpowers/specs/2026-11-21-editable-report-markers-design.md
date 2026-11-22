# Editable report markers

## Why

The post-show report finds run-of-show moments (show phases, house lights,
songs, cue calls, department gos) using phrase lists fixed in
`MarkerDetector.swift`. Different kinds of shows talk differently: a
corporate show has "keynote" and "walk-up", a circus calls "rigging go", a
concert has encores and a theatre doesn't. The user wants to tune these lists
per kind of show, from Settings.

## Goals

- See every marker rule the report uses, and change it, in a new Settings tab.
- Rules belong to the show, so each `.wilco` carries its own lists.
- Shows that were never edited behave exactly as today.

## Non-goals

- Live cue markers ("Mark Cue Point" actions). Unchanged, still in memory only.
- New marker categories. The five stay fixed: report filters, colours and the
  HTML export are built around them.
- Editing regular expressions.
- A library of presets or copying rules between shows (possible later).

## Anti-goals

- Any change to report output for a show nobody edited, including the
  `report-v1.html` fixture staying byte-identical.
- An older `.wilco` failing to open, or an unedited show's file changing.

## Approaches considered

1. **Turn the patterns into simple lists (picked).** Phrase rules become
   editable labels. The department-go regex becomes a list of department names
   that match as "X go" or "go X". Countdown and song start stay built in,
   each with an on/off switch. No regex in the UI.
2. **Raw regexes in an "Advanced" field.** Full control, but one bad edit
   silently breaks matching, and it needs validation UI.
3. **Phrases only.** Simplest, but loses "cue 47 go" and "5 minutes to"
   matching.

The user picked 1, noting they're "not sold" on it. The department list is
small and cheap to rework if it doesn't fit in practice.

## Design

### Model (`WilcoCore/Model/MarkerSettings.swift`)

```swift
public struct MarkerSettings: Codable, Equatable, Sendable {
    public var labels: [MarkerLabel]          // phrase rules, in match order
    public var departments: [String]          // "pyro", "lx", "rigging"...
    public var departmentGosEnabled: Bool
    public var countdownEnabled: Bool         // built-in "N minutes to" (Show phases)
    public var songStartEnabled: Bool         // built-in song-start pattern (Songs)
    public static let standard: MarkerSettings  // today's lists, exactly
}

public struct MarkerLabel: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var category: ShowReport.MarkerCategory   // needs Codable
    public var name: String                          // "House lights at half"
    public var isEnabled: Bool
    public var phrases: [String]
}
```

Decoding tolerates missing keys like the rest of the show.

### In the show

`ShowDocument.markers: MarkerSettings? = nil`. `nil` means "use the built-in
rules", read through `show.markerSettings` (`markers ?? .standard`).

- The synthesised encoder skips a `nil` optional, so an unedited show's file
  doesn't change.
- An unedited show picks up later improvements to the built-in lists.
- The first edit in Settings stores the full set. **Restore Defaults** sets it
  back to `nil`.

`SessionShow` already copies the whole show next to each transcript, so a
report uses the rules the session was recorded with. Edits made later don't
change that session's report. This was my call, to keep the existing
recorded-with behaviour; see "Left open".

### Detection

`MarkerDetector.detect(in:settings:)` with `settings` defaulting to
`.standard`. `ShowReportBuilder.build` passes `show.markerSettings`.

Order inside each category, first match wins, at most one per category per line:

- **Show phases:** enabled phrase labels in list order, then countdown.
- **House lights, Cue calls:** enabled phrase labels in list order.
- **Songs:** song-start pattern, then phrase labels (today's order).
- **Department gos:** each department matched against the line's words as
  `<department words> go` or `go <department words>`, plus the built-in
  `cue <number> go` / `go cue <number>`. The label is the matched words with
  the first letter capitalised, as today ("Pyro go").

Phrase matching reuses `KeywordMatcher` whole-word tokens. Blank phrases and
departments are ignored, and a label with no usable phrases never matches.
The default department list covers today's regex, with plurals listed
separately: lx, lighting, sound, audio, video, content, pyro, laser, lasers,
spot, spots, fly, deck, band, screen, screens, graphics, confetti. "go band"
etc. now match in both orders; today's regex only allowed some departments
after "go". This small widening is my call.

### Settings tab: "Markers" (`flag` symbol)

Same layout as Automation: a bordered list on the left, editor on the right,
860×600.

```
┌ Show phases ─────────┐  Name     [House lights at half      ]
│  Doors               │  [x] Enabled
│  Walk-in             │  Phrases  (house to half)(house at half)(+)
│  …                   │
├ House lights ────────┤  Lines are checked against labels top to
│▸ House lights at half│  bottom; the first match in a category wins.
├ Songs ───────────────┤
├ Cue calls ───────────┤
├ Department gos ──────┤
│  Departments         │
└──────────────────────┘
 [+▾] [–]       [Restore Defaults]
```

- Labels are grouped by category and can be reordered by dragging within a
  category, which sets match order.
- **+** is a menu: "New Label in Show phases / House lights / Songs / Cue
  calls".
- Selecting a label shows name, enabled toggle and `TokenListEditor` phrases.
- The **Show phases** and **Songs** sections each end with a built-in row
  ("Countdown", "Song start") showing just an on/off toggle and a line saying
  what it matches.
- **Departments** shows the enabled toggle and a `TokenListEditor` of names,
  with a footer: "Matches '<name> go' and 'go <name>'. 'Cue 12 go' is always
  matched."
- **Restore Defaults** asks for confirmation, then sets `markers = nil`.
- Footer under the list: "Reports use the markers saved with the show a
  session was recorded with."

### Tests (Swift Testing)

- The existing `MarkerDetectorTests` pass unchanged against `.standard`.
- Disabled labels, custom labels, an added department, list-order precedence,
  countdown/song-start switches.
- Coding: a show without `markers` decodes to `nil`; an unedited show encodes
  without the key; edited settings round-trip; partial `MarkerSettings` JSON
  fills defaults.
- `ShowReportBuilder` uses the show's settings; the `report-v1.html` fixture
  is unchanged.

### Docs

Update SPEC §8 (rules are per show and editable; the department list replaces
the regex). Add the PROGRESS entry at session end.

## Left to the builder

- File split for the Settings view, and whether built-in rows are list items
  or toggles in the section footer.
- Exact wording of footers and the confirmation.

## Left open

- If the user wants to retune after a show and see that session's report
  change, the report would need to prefer the current show's markers over the
  recorded copy. Not in this design.
