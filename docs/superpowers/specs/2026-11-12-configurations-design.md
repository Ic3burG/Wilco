# Configurations: saved show setups

Date: 2026-11-12
Status: draft for review

## Why

The user runs Wilco on different shows. Moving between them today means
rebuilding every channel, folder and input patch by hand, because Wilco keeps
exactly one show (`Current.wilco`, autosaved). ProdCom, a tool they've used,
has saved configurations you can recall. They want the same: one click
to load a whole saved show setup.

## What a configuration is

A configuration is a complete saved `ShowDocument`: channels, folders
(groups), input patch, device, automation rules, highlights, OSC
destinations, vocabulary, Whisper model and every other show field. Loading
one replaces all of it. (User's decision: everything in the show switches,
not just the patch.)

The configuration's name **is** the show's `name` field. There is no separate
label, so an exported file opens elsewhere under the same name.

## Goals

- Keep a list of named configurations inside Wilco.
- Load one in a single action.
- **Snapshot behaviour (user's decision):** loading a configuration gives a
  working copy. Edits change the working copy only. The saved configuration
  is unchanged until the user chooses **Save**. **Save As New…** makes a
  new configuration from what's on screen. **Revert to Saved** throws the
  edits away.
- Export a configuration to a `.wilco` file and import `.wilco` files,
  including older show files, which use the same format.
- Show which configuration is loaded and whether it has unsaved edits.

## Non-goals

- Recalling configurations by OSC, MIDI or HTTP. *(My call: leave it out
  for now. It's easy to add later as one more incoming command.)*
- Partial configurations (patch only, rules only).
- Sharing configurations between Macs over the network (`_wilco._tcp`
  peering is a separate, not-yet-rebuilt feature).
- Version history inside a configuration.

## Anti-goals (would count as failure even if it "works")

- Losing work: a crash, quit or power cut must never lose working-copy
  edits, and never lose a saved configuration.
- Switching while live: loading must never interrupt a capture.
- Breaking compatibility: `Current.wilco`, `.wilco` files and
  preferences must keep opening in both directions as they do now.

## Behaviour

### Working copy

- The working copy stays in `Current.wilco` and keeps autosaving exactly as
  today (debounced, `saveNow` on quit). That is what protects edits
  against a crash. Saving to a *configuration* is the separate, explicit
  action.
- Wilco remembers which configuration is loaded across launches. On launch it
  reopens the working copy, and the title still shows "— Edited" if the
  working copy differs from the saved configuration.
- **Quitting with unsaved edits doesn't ask anything.** The working copy is
  kept and is still marked Edited on the next launch. *(My call: this
  matches today's autosave, and a prompt at quit is easy to dismiss by
  mistake in a hurry after a show.)*
- **Edited** means `workingCopy != savedConfiguration`, using `ShowDocument`'s
  existing `Equatable`. Undoing a change by hand clears the flag. *(My call.)*

### Loading

- **Refused while capturing (user's decision).** The Load command and the
  configuration items in the title menu are disabled while capturing. If
  load is reached anyway (for example from the Configurations window), it
  shows: "Stop capture before loading a different configuration."
- **Unsaved edits:** loading a different configuration asks *Save changes to
  "Arena Tour" before loading "Theatre — Small"?* with Save / Don't Save /
  Cancel.
- **Clears the on-screen transcript and activity (user's decision).** Every
  line is already written to the session `.jsonl`, so nothing is lost. It
  can still be opened in the report.
- Selection resets to Combined if the selected channel or folder doesn't
  exist in the new configuration (`SidebarItem.validated(in:)` already does
  this). Collapsed folders are keyed by folder UUID, so they carry over
  harmlessly.
- A configuration made on another Mac may name an audio device or Whisper
  model this Mac doesn't have. Loading still works. The existing handling
  applies (the device shows as not connected; the model shows Install in
  Settings → Languages). Loading never rewrites the device UID or model
  to fit this Mac.
- Loading the configuration that's already loaded does nothing (use Revert
  to throw edits away).

### Save, Save As New, Revert

- **Save (⌘S):** writes the working copy into the loaded configuration. It
  is allowed while capturing, because it doesn't change what's running.
- **Save As New… (⇧⌘S):** asks for a name (default: the current name plus
  " copy"), creates a configuration from the working copy, and makes it
  the loaded one. The working copy's `name` becomes the new name.
- **Revert to Saved:** replaces the working copy with the saved
  configuration. It asks first, and is refused while capturing like Load,
  since it can change channels. It does **not** clear the transcript. *(My
  call: it's the same show.)*

### Title menu (placement B, user's choice)

The window title shows the loaded configuration's name, plus " — Edited"
when the working copy has unsaved changes. Clicking the title opens a menu
with:

- every configuration by name, with a tick on the loaded one (choosing one
  loads it)
- Save "‹name›" ⌘S
- Save As New… ⇧⌘S
- Revert to Saved
- Manage Configurations… ⇧⌘O

The same commands go in the **File** menu, together with **Import
Configuration…** and **Export Configuration…** (exporting the loaded one).

*Builder's choice:* how to make the title clickable in SwiftUI on macOS 15.
`.navigationTitle` plus `.toolbarTitleMenu` is the native route (it gives
the title a menu like in Pages). If that doesn't render well with the
inspector toolbar, a principal toolbar item that looks like the title is
fine.

### Configurations window (placement C, user's choice)

A separate window (`Window` scene, opened by Manage Configurations… or
File ▸ Configurations…), with:

- a list of every configuration: name, channel count, date last saved,
  and a tick on the loaded one; sorted by name *(my call)*
- **New:** creates a blank show (`ShowDocument()`) as a configuration named
  "New Show" (or "New Show 2" and so on). It doesn't load it.
- **Duplicate:** copies the selected saved configuration as "‹name› copy".
- **Rename:** renames the saved file's `name`. If it's the loaded
  configuration, the working copy's `name` changes too, without marking
  it Edited.
- **Delete:** asks first. **Disabled for the loaded configuration** *(my
  call)*, so something is always loaded and the title always has a name.
- **Import…:** an open panel for `.wilco` files (several at once). Each
  becomes a new configuration and is not loaded. If a name is taken, the
  import gets " 2", " 3" and so on. Unreadable files are listed in one
  message; the readable ones still import.
- **Export…:** a save panel for the selected configuration's **saved**
  version, named `‹name›.wilco`. *(My call: the working copy isn't
  exported. Save first.)*
- **Load:** the same rules as above. Double-clicking a row also loads.

Names must be non-empty after trimming. Two configurations may not share a
name (case-insensitive), so the title menu is unambiguous.

### First launch after upgrading

If there are no configurations yet, Wilco creates the first one from the
current `Current.wilco`, under its existing name (often "New Show"), and
marks it loaded and not edited. With no `Current.wilco` at all, it creates
"New Show" from a blank `ShowDocument()`. Nothing the user had is lost or
renamed.

## Storage

- Folder: `DataLocations.root/Configurations/` (alongside `Current.wilco`).
- One file per configuration, `‹UUID›.wilco`, holding a plain
  `ShowDocument` JSON in exactly the format of `Current.wilco` and
  exported shows. The UUID gives a stable identity, so renaming never moves files.
  The display name comes from the `name` inside. *(My call.)*
- The loaded configuration's UUID is stored in `UserDefaults`
  (`configurations.loaded`). *(My call.)* If it points to a file that has
  gone, Wilco treats the working copy as unsaved: the title shows the name
  with "— Not Saved", and Save behaves like Save As New.
- Writes are atomic (`Data.write(options: .atomic)`), as `ShowStore` does now.
- `ShowDocument` gains **no new fields**, so the format stays exactly
  as it is.

## Where the code goes

Following the repo rule (logic in the package, app target thin):

- **WilcoCore / Persistence:** a `ConfigurationStore` (list, read, create,
  save, rename, duplicate, delete, import, export, first-run migration,
  unique-name rule). Pure file I/O plus `ShowDocument`, fully unit-tested
  against a temporary directory. It includes a test that a real show
  fixture from `Tests/WilcoCoreTests/Fixtures` imports and round-trips.
- **App / `AppModel`:** the loaded configuration ID, the saved snapshot for
  the Edited comparison, and the `load` / `save` / `saveAsNew` / `revert`
  actions, with the capture and unsaved-edits guards. Loading clears
  `timeline` and activity, re-validates the selection, and goes through
  the same path that sets `document` today, so autosave and
  device/transcriber reconciliation behave as for any other show change.
- **App / UI:** the title menu, the File menu commands, the Configurations
  `Window`, and the confirmation dialogs.

## Testing

- Unit tests (`swift test`) for `ConfigurationStore`: create/list/rename/
  duplicate/delete, unique names, import of a real show fixture, import of an
  unreadable file, export round-trip byte-for-byte as `ShowDocument`,
  first-run migration with and without `Current.wilco`, and a missing
  loaded-ID file.
- The edited-flag logic and the load guards (capturing, unsaved edits) are
  model logic. Where they can be pure functions, they go in the package
  with tests.
- In-app check by the user (to count as "verified"): save two setups,
  switch between them, confirm the patch, rules and OSC destinations all
  swap, the transcript clears, loading is refused while capturing, and
  export → import on another Mac or account opens.

## Left to the builder

- The SwiftUI mechanism for the title menu (see above).
- Window size and layout of the Configurations window. Match the existing
  Settings and Report windows.
- Exact wording of the dialogs, in the app's plain style.
