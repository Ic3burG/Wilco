# Settings redesign: sidebar split into This Show and This Mac

Date: 2026-11-25

## Intent

Settings has grown to eight toolbar tabs (General, Look & Feel, Audio,
Languages, Learning, Automation, Markers, Destinations) in one fixed
860×600 window. The owner designed every part of it and finds things
easily; the concern is **other users**, who build their own show from
scratch because every show is different. For them, Settings today:

- mixes preferences for this Mac (quit prompt, appearance, keeping clips)
  with things saved in the show (device, vocabulary, rules, markers,
  destinations) and gives no hint which is which;
- gives no order to work through when setting up a new show;
- spreads model downloads across Languages and Learning ("Install in
  Languages");
- explains itself in long footer paragraphs on almost every section.

The work is a **reorganisation and a visual refresh**, together.

## Goals

- One Settings window (still ⌘,) with a sidebar in two groups:
  **This Show**, numbered in setup order, and **This Mac**.
- A newcomer can tell where a setting lives from the sidebar alone.
- Each show step shows a tick once it looks set up, as a hint, not a gate.
- A search field that finds any setting by name and jumps to its page.
- All model downloads in one place.
- Shorter on-page text: one-line captions, longer explanations behind a
  visible ⓘ button.

## Non-goals

- No change to `ShowDocument`, `.wilco` files or any stored format. Only
  where controls appear changes.
- No new settings and no removed settings. (One new download button,
  Apple long-form for learning, is a download, not a setting.)
- No setup wizard or forced order: every page stays reachable at any time.
- No "open Settings at page X" from elsewhere in the app yet (approach 1
  leaves room for it later).

## Anti-goals (a failure even if it works)

- The owner's own workflow gets slower, or a control they use becomes
  harder to reach.
- Controls hidden behind hover effects or overflow menus. Everything stays
  visible and one click away (standing preference).
- Any older show, preference or model folder stops opening.
- Per-channel knobs creeping into Settings, or show-wide options leaving
  it (standing preference: show-wide options live in Settings).

## Constraints

- Deployment target macOS 15; CI builds with Xcode 26.6. Use only APIs
  available there (`NavigationSplitView`, `.searchable`, `List(selection:)`
  in a `Settings` scene are all macOS 13+).
- Swift 6 strict concurrency, warnings fixed not silenced.
- Testable logic (search index, tick rules) goes in `WilcoCore` with Swift
  Testing tests; the app target stays thin.
- Security model §5 checklist answered below.

## Approaches considered

**Layout** (shown as browser mockups; owner picked A):

- **A. One window, sidebar split into This Show / This Mac.** Picked. Gives
  newcomers both the show/Mac split and a setup order, and keeps
  show-wide options in Settings.
- B. Small Settings for this Mac plus a separate Show Setup window. Each
  window is clean, but show setup becomes a second place to discover.
- C. Keep toolbar tabs, merge 8 into 5. Least change, but still no
  show/Mac split, which is the main source of confusion.

**Build** (owner picked 1):

- **1. Keep the SwiftUI `Settings` scene and put a `NavigationSplitView`
  inside it.** Picked. ⌘, and the app menu item keep working untouched;
  existing editors move over largely as they are.
- 2. Replace it with an ordinary `Window` scene. Resizable, real toolbar,
  easy deep links, but ⌘, and the menu item need wiring by hand and macOS
  no longer treats it as the app's Settings window.

## Design

### Sidebar and pages

```
🔍 Search
THIS SHOW
  1 Audio                 ✓
  2 Speech
  3 Destinations
  4 Rules & Highlights
  5 Markers
THIS MAC
  ⚙︎ General
  Aa Appearance
  ⬇︎ Speech Models
  🎓 Learning
```

Show steps carry a number badge; Mac pages carry an SF Symbol. The
selected page is remembered across launches (`UserDefaults`
`settings.selectedPage`, the page's raw value; unknown or missing falls
back to Audio). The spec mentions `settings.selectedTab`, which was never
stored, so nothing old needs migrating.

What moves where (every control keeps its current binding):

| New page | Contents | From today |
|---|---|---|
| **1 Audio** | Show device, Refresh Devices, capture health | Audio (unchanged) |
| **2 Speech** | New-channel engine and language; Whisper model *choice* (`document.whisperModel`); global vocabulary; voice-change tuning (threshold, exchange gap, Restore Defaults) | Languages |
| **3 Destinations** | OSC destinations | Destinations (unchanged) |
| **4 Rules & Highlights** | Rules and highlights list + editor, Test Rule | Automation (renamed) |
| **5 Markers** | Marker lists, presets, Restore Defaults | Markers (unchanged) |
| **General** | Ask to save on quit | General |
| **Appearance** | Theme, text size, transcript toggles | Look & Feel (renamed) |
| **Speech Models** | Every download, in two sections: *For this show's channels* (Whisper download and other Whisper sizes on disk, Parakeet + vocabulary model, voice model, Apple per-language rows) and *For learning* (Parakeet Ultra, Whisper large-v3, voice grouping, and Apple long-form en-US with its own Install button, so it can be installed even when no channel uses that engine — today it can't be) | Languages + Learning |
| **Learning** | Keep clips, space used, Delete All Clips, background labelling status; voter readiness as a read-only list ("2 of 4 voters installed") with a visible **Speech Models…** button that selects that page | Learning |

Speech Models is under This Mac because downloads are shared by every
show on the Mac, even though which ones are *needed* depends on the show.
Its "For this show's channels" rows stay driven by the current show, as
today.

### Ticks

A tick means "looks set up", computed live; there is no stored state.
Owner's call accepted by default (not objected to when proposed):

- **Audio:** the show has at least one channel, and its device
  (`deviceUID`; `nil` means System Default) is System Default or is
  connected right now. A saved device that is unplugged leaves it
  unticked. *(Builder-check call: without the "connected" part the tick
  only checked for channels.)*
- **Speech:** every engine/language the show's channels use is installed.
  No channels → no tick.
- **Destinations:** at least one destination enabled.
- **Rules & Highlights:** at least one rule *or* highlight enabled.
  *(Builder-check call: a show that only uses highlights should still be
  ticked.)*
- **Markers:** never ticked; the built-in defaults already work.

A missing tick is shown as nothing (no warning colour). Accessibility
label reads "Audio, set up" / "Audio".

Logic lives in `WilcoCore` as `ShowSetupProgress`, taking a
`ShowDocument`, the set of connected device UIDs, and a predicate for "is
this engine + locale installed". The package therefore needs no knowledge
of CoreAudio or the installer. Tests cover each rule, including an
imported show: `OutboundRules.turningOff(in:)` switches off rules that
send off the local network (it leaves destinations alone), so a show
whose only rules were switched off on import, with no highlights, is
unticked under Rules & Highlights.

### Search

`.searchable` on the sidebar. While the field has text, the sidebar list
is replaced by matching results, each "Setting name — Page"; choosing one
clears the search and selects the page. No match shows "No settings
match".

The index is a fixed list in `WilcoCore` (`SettingsIndex`: entries of
title, extra keywords, page id), written by hand from the controls above,
roughly 40 entries. Matching: case- and diacritic-insensitive; every word
typed must prefix some word of the title or keywords ("voc" finds
Vocabulary; "osc" finds Destinations via a keyword). Tests cover matching
and that every page has at least one entry. Scrolling to or highlighting
the control itself is out of scope (builder may add it if cheap).

### Visual refresh

- Each page opens with its title and a one-line description of what it is
  for (for example, Speech: "How this show's channels are transcribed.").
- Footer paragraphs shrink to one line. The rest moves into an **ⓘ**
  button at the end of that line, which opens a popover with the existing
  text. One shared `InfoButton` component in `Wilco/Components`.
- Keep `.formStyle(.grouped)` cards; drop the fixed size per tab. Window
  minimum about 900×600 (sidebar ~200, content as today), resizable via
  `.windowResizability(.contentMinSize)`; the list-and-editor pages
  (Rules, Markers) use the extra room. Check this first. If the
  `Settings` scene won't resize on macOS 15, use a fixed size of about
  1060×640 and don't reach into `NSWindow` *(builder-check call)*.
- Existing destructive buttons and confirmation alerts are unchanged.

### Text that names old tabs

Update to the new names: `AppModel.swift:369` and
`AppModel+Configurations.swift:237` (Automation → Rules & Highlights),
`AutomationSettingsView.swift:218` (still Destinations), the two in
`LearningSettingsView` (now Speech Models), `ShowReview.swift:492`,
`BenchEngine.swift:93` (Languages → Speech Models), and the Settings
paragraph plus "Settings › …" references in `docs/SPEC.md` (Learning,
Languages › New Channels, Markers, Automation).

## Security (§5 checklist)

1. Reads nothing new. 2. Nothing a show can switch on. 3. Sends nothing.
4. Listens to nothing. 5. Does not act on speech. 6. Shows show text only
where it already does (rule names, destination names); the search index is
fixed app text, never show content. 7. Search over ~40 fixed strings
can't stall. 8. No dependency, entitlement or Info.plist key. 9. Writes
one new preference, `settings.selectedPage`, a short string; unknown
values fall back to Audio, so a hand-edited preference can't break
anything.

## Left to the builder

- Exact SF Symbols, one-line captions and page descriptions (plain style,
  as in the rest of the app).
- Exact wording of search keywords.
- File layout inside `Wilco/Settings` (likely one file per page, splitting
  `LanguagesSettingsView` into Speech and Speech Models).
- Whether search highlights the matched control.
