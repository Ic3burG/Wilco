# Marker presets

## Why

The user usually starts a new show from scratch and wants to pull in marker
lists that suit it ("Concert", "Theatre", "Corporate") rather than retyping
phrases. Builds on per-show markers
(`2026-11-21-editable-report-markers-design.md`).

## Goals

- Save the current show's marker lists as a named preset.
- Load a preset into any show as a starting point; edit freely afterwards.
- Rename and delete presets.

## Non-goals and anti-goals

- No merging: loading replaces the show's whole marker set.
- No copying from other saved shows (approach 3; can be added later).
- No import/export UI. Presets are plain files a user can copy by hand.
- Anti-goal: a preset change silently altering a show. Shows hold their own
  copy; presets are only read on load.

## Approaches

1. **Marker presets in an app-wide folder (picked).** A Presets menu in the
   Markers tab, with files in `Presets/Markers/`.
2. Copy markers from another saved show. No new storage, but the user would
   have to keep dummy template shows.
3. Both in one menu. More to explain; add the show list later if needed.

## Design

- **Storage.** `MarkerPresetStore` in `WilcoCore/Persistence`, modelled on
  `ConfigurationStore`. The folder is
  `DataLocations.markerPresets = root/Presets/Markers`, one `‹UUID›.json` per
  preset: `MarkerPreset { name: String, markers: MarkerSettings }`, decoding
  missing keys to defaults.
  - The UUID is the identity, so renaming never moves a file.
  - Names are unique ignoring case. Unreadable files are skipped and left
    alone.
- **Store operations.**
  - `list()` returns presets sorted by name.
  - `preset(id)` reads one.
  - `save(name:markers:)` either creates a preset or, when the name is
    already taken, replaces the preset with that name.
  - `rename(id, to:)` throws on an empty or taken name.
  - `delete(id)`.
- **Markers tab.** A **Presets** menu sits in the bottom bar next to Restore
  Defaults:
  - **Save as Preset…** opens a sheet with a name field. If the name already
    exists it asks "Replace the “Concert” preset?".
  - Below that, each preset by name. Choosing one loads it. If the show
    already has its own edited markers, it first confirms "Replace this
    show's markers with “Concert”?". If the show is on the built-ins, it loads
    without asking.
  - **Manage Presets…** opens a sheet listing presets with rename and delete
    (delete asks for confirmation).
- **Loading** sets `model.document.markers` to a copy of the preset's
  settings. Restore Defaults still returns the show to the built-ins.
- **Tests (Swift Testing, temp directory).** Cover:
  - save and list round-trip;
  - saving under an existing name, in any case, replaces it;
  - rename, including a taken name and an empty name;
  - delete;
  - unreadable files are skipped;
  - a preset with missing keys decodes.
- **Docs.** Add a SPEC §8 line and a data-locations row for
  `Presets/Markers/`.

## My calls

- Saving under an existing name replaces that preset after confirmation,
  rather than creating "Concert 2".
- Loading doesn't ask when the show is still on the built-in lists, because
  nothing would be lost.
- No built-in presets ship with the app. "Defaults" is the only built-in set.
