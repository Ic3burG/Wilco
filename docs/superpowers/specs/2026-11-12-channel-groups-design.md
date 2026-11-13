# Channel groups — design

Date: 2026-11-12. Status: agreed with the user in conversation; ready to plan.

## Why

On a busy show the user wants to watch one kind of traffic at a time,
such as "only the radio channels", without losing the rest. The show
format already had groups (`ShowDocument.groups`, `ChannelConfig.groupID`),
but the app never had a working UI for them. Its recovered strings contain no
group copy at all. This feature makes groups real.

**Groups are a way of viewing.** Selecting a group filters what you see.
Nothing about capture or control changes.

## Goals

1. Group channels into folders in the sidebar, Finder-style.
2. Click a folder to see the chat from only that group's channels.
3. In the Matrix, switch between one column per channel and one column per
   group.
4. In the post-show report (and its HTML export), filter by group with one
   click.
5. Groups round-trip through the `.wilco` file using the format's existing fields.

## Non-goals

- Groups don't start, stop, mute, route or meter anything at capture level.
  Automation rules and highlights stay scoped to channels, not groups.
- No nested groups. No channel in two groups.
- No per-group totals or stats in the report beyond what the filter already
  gives (see Report).

## Anti-goals (it would be a failure if…)

- Opening an older show, or a show saved by this build, lost or scrambled
  group membership or channel order.
- Grouping, ungrouping or deleting a group affected transcription,
  automation or a running session in any way.
- Deleting a group deleted its channels, or a deleted or missing group left
  channels invisible in the sidebar.

## Data model (existing, unchanged on disk)

- `ShowDocument.groups: [ChannelGroup]`. `ChannelGroup { id, name, symbol }`
  is already Codable and in the show format.
- `ChannelConfig.groupID: UUID?`. At most one group per channel, by
  construction.
- **Sidebar order** *(revised 2026-11-12 after user testing)*: folders and
  ungrouped channels can be placed **anywhere** among each other, like Finder.
  The top-level order is stored in a new optional show-file field,
  `sidebarOrder`: an array of `"group:<uuid>"` / `"channel:<uuid>"` strings.
  Readers that ignore unknown keys still open these shows. If such a reader
  re-saves a show, only the top-level positions are lost. Without the field
  (any older show), the order is folders in `groups` order, then ungrouped channels, in
  `channels` order. Each folder lists its channels in `channels` array order.
  Stale or unknown entries are dropped. Groups and ungrouped channels missing
  from it are appended at the end.
- A `groupID` naming a group that doesn't exist is treated as ungrouped
  everywhere: displayed with the ungrouped channels, and cleared the next
  time the document is edited. *(my call)*
- New `ShowDocument` operations in `ShowDocument+Channels.swift` (or a new
  `+Groups` file), addressed by ID like the existing channel edits:
  add group, rename, set symbol, delete group (clears `groupID` on its
  channels), move group, assign a channel to a group or to none.
  Unit tests for each, plus round-trip encode/decode of a show with groups.
- **One display order everywhere.** The Combined chips, Matrix columns
  (Channels mode) and report chips follow the sidebar order, not raw array
  order. How the builder gets there (keeping `channels` sorted to match on
  every edit, or computing a display order) is left to the builder. Keeping
  the array in sidebar order is simpler and makes code that reads only `channels` see the same order.

## Sidebar

Layout (mockup option A, chosen by the user): folders live inside the
existing **Channels** section.

- **Folder row:** disclosure triangle, the group's symbol (default `folder`),
  name, and a count of its channels. Collapsed or expanded state is
  **remembered per Mac** in UserDefaults, like other view state, not saved in
  the show file. A **collapsed** folder shows one level meter: the loudest of
  its channels.
- **Channel rows** inside a folder are indented and otherwise unchanged
  (meter, status, unpatched and muted glyphs, context menu).
- **New Group** button beside **Add Channel** in the bottom bar (SF Symbol
  `folder.badge.plus`). It creates "New Group" at the end of the folder
  list, selects it and starts an inline rename, as Finder does.
- **Drag and drop:**
  - drop a channel on a folder to move it into that group (from another
    group or from ungrouped);
  - drag a channel out to the ungrouped area to ungroup it;
  - drag within a folder or within the ungrouped list to reorder, as now;
  - drag folders to reorder them.
- **Folder context menu:** Rename, Change Icon, Delete Group. Delete removes
  only the group, and its channels become ungrouped. No confirmation, because
  nothing is lost. *(my call)* Delete key on a selected folder does the same.
- **Inspector:**
  - the existing **Group** picker in `ChannelInspector` stays. Show it even
    when there are no groups, with only "None", plus a "New Group…" item.
    *(my call)*
  - selecting a folder shows a small **Group inspector**: Name, Symbol
    (picker in the same style as the channel symbol picker, with a few
    folder-ish symbols such as `folder`, `antenna.radiowaves.left.and.right`,
    `rectangle.3.group`, `theatermasks`, `video`, `lightbulb`, `music.mic`),
    and the member channels listed.
- Empty state: unchanged ("No channels configured yet.").

## Selecting a group

- New `SidebarItem.group(UUID)`, persisted as `"group:<uuid>"` in
  `sidebar.selection`. `validated(in:)` falls back to `.combined` when the
  group no longer exists. Deleting the selected group moves selection to
  `.combined` first, matching how channel deletion already avoids the stale-index
  crash.
- Detail: the combined transcript restricted to the group's channels. The
  live header shows the group's symbol and name and its channel chips. The
  chips narrow further *within* the group, like the Combined chips do now.
  Each view keeps its own chip state, so narrowing in a group doesn't
  change Combined. *(my call)*
- Clicking a channel inside a folder still shows that channel alone,
  exactly as today.
- Markers follow the same filter rules as the Combined view.

## Matrix: Channels | Groups

- A segmented **Channels | Groups** switch in the Matrix toolbar,
  remembered per Mac (a new `matrix.*` default).
- **Channels:** today's matrix, one column per channel, in sidebar order.
- **Groups:** one column per group, in folder order, then one column per
  ungrouped channel. A group column interleaves its channels' lines by
  time, and each line is tagged with its channel's name in the channel tint.
  The column header shows the group symbol, name and "N channels".
- Width, collapse and per-column text size work for group columns as they
  do for channel columns, keyed by the group's UUID in the existing
  `MatrixLayout` stores (UUIDs don't collide with channel IDs). "Fit" and
  "Expand all" act on whichever columns are visible.
- A group with no channels gets no column. *(my call)*

## Post-show report and HTML export

- **Group chips** go at the start of the channel chip row, after "All
  channels": `All channels · 📁 Radios · 📁 Stage | Radio 1 · Radio 2 · …`.
- Clicking a group chip **adds all its channels** to `channelFilter`, and
  clicking it again removes them. A group chip shows as on when all of its
  channels are in the filter. Individual channel chips still toggle singly.
- The filter applies wherever channel chips already apply: Run of show,
  chat log and the Channels tab stats.
- The report uses the show's **current** groups, because transcripts record
  the channel, not the group. Rearranging folders after a show changes how
  that show's report groups. The user accepted this.
- Channels that appear in the transcripts but no longer exist in the show
  have no group, and only their channel chip appears.
- HTML export: the same group chips with the same behaviour in its inline
  script (a `data-group` attribute listing member channel IDs).
- SRT/VTT export: unchanged.

## Reordering must not restart capture (existing bug, fix first)

`AppModel.document.didSet` restarts capture when
`document.captureTaps != oldValue.captureTaps`, and `captureTaps` follows
`channels` array order (`Capture.swift`). So today, **dragging a channel to
reorder it during a session restarts capture**, and with groups every move
into or out of a folder would too. That breaks the anti-goal above.

Fix *(my call)*: compare the taps **without regard to order**. For example,
give `ShowDocument` a helper that says whether capture needs restarting,
comparing tap sets keyed by channel ID. Restart only when a tap is added,
removed or changes device or input. This also fixes the existing reorder
glitch, and lets the builder keep `channels` in sidebar order. Add a
regression test: reordering channels and changing `groupID` leave the
capture comparison unchanged. Changing `groupID` alone doesn't restart a
transcriber, because `TranscriberConfiguration` doesn't include it. Keep it
that way.

## Constraints

- Deployment target macOS 15, so the sidebar outline and drag-drop must work
  there. CI builds with Xcode 26.6, so no Xcode 27-only APIs without guards
  (see `CLAUDE.md`).
- Logic in `WilcoCore` with Swift Testing tests. The app target stays thin.
- Swift 6 strict concurrency. The audio thread is untouched by this feature.
- The show file format is unchanged. Nothing new is written to disk,
  since group collapse and the matrix mode are UserDefaults.

## Sidebar list control *(revised 2026-11-12 after user testing)*

SwiftUI's `List` asserted (`OutlineListCoordinator.performDropInsertion`) on
between-row drops in a section mixing folders and loose rows. Row-only drops
lost the insertion line and showed a "+" copy badge. The sidebar is therefore
an **`NSOutlineView` (source-list style)** bridged into SwiftUI:
- it shows the native insertion line, including the indented line for "into
  this folder", and a move cursor;
- folders only go at the top level;
- rows remain SwiftUI views hosted in the cells;
- context menus are AppKit menus;
- the drag payload is a private pasteboard type, so it doesn't paste into
  other apps.

## Left to the builder

- How the sidebar outline and drag-drop are built in SwiftUI (`List` with
  `DisclosureGroup`, `OutlineGroup`, `onMove`/`dropDestination`, or an
  `NSOutlineView` bridge if SwiftUI can't do drop-onto-folder well on
  macOS 15).
- Whether display order is enforced in the array or computed.
- Exact names of new types, defaults keys and files.
- Animation details (use `look.animation` like the rest of the sidebar).

## Done means

- Package tests for the group operations, the order rules, missing-group
  handling, `SidebarItem.group` storage and validation, group filtering in
  the report, and show round-trip with groups.
- App builds on CI.
- The user tries it in the app: make Radios, drag channels in, click it, see
  only radio chat; switch the Matrix to Groups; filter the report and the
  HTML export by group. Only then does `PROGRESS.md` call it verified.
