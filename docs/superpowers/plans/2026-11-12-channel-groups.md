# Channel Groups Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the user put channels into sidebar folders, click a folder to see
only that group's chat, show the Matrix by channel or by group, and filter the
post-show report and its HTML export by group.

**Architecture:** Groups already exist in the 0.2.0 show format
(`ShowDocument.groups`, `ChannelConfig.groupID`). All ordering, filtering and
column logic goes into `WilcoCore` as pure functions with Swift Testing
tests. The app target (`Wilco/`) only renders them. A new
`ChannelScope` (all / one channel / one group) replaces the transcript view's
`channelID: UUID?`, so the Combined, channel and group views share one code
path.

**Tech Stack:** Swift 6 (strict concurrency), SwiftUI on macOS 15+,
Swift Testing, SwiftPM package `Packages/WilcoCore`.

**Spec:** `docs/superpowers/specs/2026-11-12-channel-groups-design.md`.
Read it first. It holds the reasons and the user's decisions.

## Global Constraints

- Deployment target macOS 15. CI builds with Xcode 26.6: no Xcode 27-only
  APIs unless guarded.
- Nothing new is written to the `.wilco` file. Folder collapse state and
  matrix mode are UserDefaults only.
- Groups never affect capture, transcription, mute or automation.
- One group per channel. No nested groups.
- Default group symbol `folder`. New groups are named `New Group`.
- Display order everywhere: folders in `groups` order, each folder's
  channels in `channels` order, then ungrouped channels in `channels` order.
- Every edit addresses channels and groups by ID, never by a held index
  (see the comment at the top of `ShowDocument+Channels.swift`).
- Tests: `cd Packages/WilcoCore && swift test`. App build: the
  `xcodebuild` command in `CLAUDE.md`.

## Review Focus

1. **Grouping during a live session.** Dragging a channel into a folder,
   reordering, or deleting a group while capturing must not restart capture.
   Pinned in Task 1.
2. **Deleting the selected group, or the group of the selected channel.**
   The selection must land on Combined (for a group) or stay on the channel,
   never on a missing item. Pinned in Task 3.
3. **A `groupID` naming no group** (hand-edited file, a future peer). The
   channel must still appear, as ungrouped. Pinned in Task 2.
4. **Group names with `<`, `&` or quotes** in the HTML export must be
   escaped, like channel names. Pinned in Task 8.
5. **Empty groups.** Selecting one shows the empty state. It gets no
   matrix column and no report chip. Pinned in Tasks 4, 7 and 8.

---

### Task 1: Reordering must not restart capture

**Files:**
- Modify: `Packages/WilcoCore/Sources/WilcoCore/Audio/Capture.swift` (extension `ShowDocument`, near `captureTaps`)
- Modify: `Wilco/AppModel.swift:22`
- Test: `Packages/WilcoCore/Tests/WilcoCoreTests/ChannelEditingTests.swift`

**Interfaces:**
- Produces: `ShowDocument.capturesSameInputs(as other: ShowDocument) -> Bool`

- [ ] **Step 1: Write the failing tests** (new `@Suite("Capture restarts")` in `ChannelEditingTests.swift`)

```swift
@Test func reorderingChannelsKeepsTheSameInputs() {
    var show = ShowDocument()
    for _ in 0..<3 { show.addChannel() }
    let before = show
    show.moveChannels(fromOffsets: [0], toOffset: 3)
    #expect(show.capturesSameInputs(as: before))
}

@Test func changingAGroupKeepsTheSameInputs() {
    var show = ShowDocument()
    let channel = show.addChannel()
    let before = show
    show.updateChannel(id: channel.id) { $0.groupID = UUID() }
    #expect(show.capturesSameInputs(as: before))
}

@Test func repatchingAChannelChangesTheInputs() {
    var show = ShowDocument()
    let channel = show.addChannel()
    let before = show
    show.updateChannel(id: channel.id) { $0.deviceChannel = 7 }
    #expect(!show.capturesSameInputs(as: before))
}
```

- [ ] **Step 2: Run them to make sure they fail**

Run: `cd Packages/WilcoCore && swift test --filter "Capture restarts"`
Expected: build failure, `capturesSameInputs` not found.

- [ ] **Step 3: Implement `capturesSameInputs(as:)`**: compare `Set(captureTaps)` (`CaptureTap` is already `Hashable`).

- [ ] **Step 4: In `AppModel.document.didSet`, replace `document.captureTaps != oldValue.captureTaps` with `!document.capturesSameInputs(as: oldValue)`.**

- [ ] **Step 5: Run the package tests and build the app**

Run: `swift test` then the `xcodebuild` command from `CLAUDE.md`.
Expected: all tests pass, `BUILD SUCCEEDED`.

- [ ] **Step 6: Commit** with the message `Don't restart capture when channels are only reordered`.

---

### Task 2: Group editing and display order in the model

**Files:**
- Create: `Packages/WilcoCore/Sources/WilcoCore/Model/ShowDocument+Groups.swift`
- Create: `Packages/WilcoCore/Tests/WilcoCoreTests/ChannelGroupTests.swift`

**Interfaces:**
- Produces (all on `ShowDocument`, `public`):
  - `func group(id: ChannelGroup.ID) -> ChannelGroup?`
  - `func effectiveGroupID(of channel: ChannelConfig) -> ChannelGroup.ID?`: `nil` when the channel's `groupID` names no group.
  - `func channels(inGroup id: ChannelGroup.ID?) -> [ChannelConfig]`: `nil` means ungrouped, uses `effectiveGroupID`, in `channels` order.
  - `var channelsInDisplayOrder: [ChannelConfig]`
  - `@discardableResult mutating func addGroup(name: String = "New Group", symbol: String = "folder") -> ChannelGroup`: appended at the end.
  - `mutating func renameGroup(id:to:)`: trims whitespace and ignores an empty result.
  - `mutating func setGroupSymbol(id:_ symbol: String)`
  - `mutating func deleteGroup(id:)`: removes the group and sets the `groupID` of its channels to `nil`.
  - `mutating func moveGroups(fromOffsets: IndexSet, toOffset: Int)`: same semantics as `moveChannels`.
  - `mutating func assignChannel(_ channelID: ChannelConfig.ID, toGroup groupID: ChannelGroup.ID?)`: the channel goes to the **end** of the target group's run (or of the ungrouped run). A non-existent `groupID` is ignored.
  - `mutating func moveChannels(inGroup groupID: ChannelGroup.ID?, fromOffsets: IndexSet, toOffset: Int)`: offsets are relative to `channels(inGroup:)`, which is what a `List` section's `onMove` hands over.
  - `private mutating func normalizeChannelOrder()`: stable-reorders `channels` into display order and clears dangling `groupID`s. Every mutating group operation above calls it last.

- [ ] **Step 1: Write the failing tests** in `ChannelGroupTests.swift`, `@Suite("Channel groups")`. A helper `makeShow()` builds channels A, B, C, D and groups Radios and Stage.

```swift
@Test func displayOrderIsFoldersThenUngrouped() {
    // A→Stage, B→nil, C→Radios, D→Radios; groups [Radios, Stage]
    #expect(show.channelsInDisplayOrder.map(\.name) == ["C", "D", "A", "B"])
}
@Test func assigningMovesChannelToEndOfGroupAndKeepsArrayInDisplayOrder() {
    show.assignChannel(b.id, toGroup: radios.id)
    #expect(show.channels(inGroup: radios.id).map(\.name) == ["C", "D", "B"])
    #expect(show.channels.map(\.id) == show.channelsInDisplayOrder.map(\.id))
}
@Test func assigningToNilUngroups() {
    show.assignChannel(c.id, toGroup: nil)
    #expect(show.channels(inGroup: nil).map(\.name) == ["B", "C"])
}
@Test func assigningToMissingGroupDoesNothing() {
    let before = show
    show.assignChannel(b.id, toGroup: UUID())
    #expect(show == before)
}
@Test func deletingAGroupKeepsItsChannelsUngrouped() {
    show.deleteGroup(id: radios.id)
    #expect(show.groups.map(\.name) == ["Stage"])
    #expect(show.channels.count == 4)
    #expect(show.channels(inGroup: nil).map(\.name).sorted() == ["B", "C", "D"])
}
@Test func danglingGroupIDShowsAsUngrouped() {
    show.channels[0].groupID = UUID()   // set directly, as a decoded file could
    #expect(show.effectiveGroupID(of: show.channels[0]) == nil)
    #expect(show.channelsInDisplayOrder.count == 4)
}
@Test func renameIgnoresBlankNames() {
    show.renameGroup(id: radios.id, to: "  ")
    #expect(show.group(id: radios.id)?.name == "Radios")
    show.renameGroup(id: radios.id, to: " Comms ")
    #expect(show.group(id: radios.id)?.name == "Comms")
}
@Test func movingWithinAGroupUsesGroupRelativeOffsets() {
    show.moveChannels(inGroup: radios.id, fromOffsets: [1], toOffset: 0)
    #expect(show.channels(inGroup: radios.id).map(\.name) == ["D", "C"])
}
@Test func movingGroupsReordersFolders() {
    show.moveGroups(fromOffsets: [1], toOffset: 0)
    #expect(show.channelsInDisplayOrder.map(\.name) == ["A", "C", "D", "B"])
}
@Test func showWithGroupsRoundTrips() throws {
    let data = try WilcoJSON.encoder.encode(show)   // use whatever ShowStore uses
    #expect(try WilcoJSON.decoder.decode(ShowDocument.self, from: data) == show)
}
@Test func newGroupDefaults() {
    let g = show.addGroup()
    #expect(g.name == "New Group"); #expect(g.symbol == "folder"); #expect(show.groups.last == g)
}
```

Check `WilcoJSON` for the real encoder/decoder names.

- [ ] **Step 2: Run them to make sure they fail**: `swift test --filter "Channel groups"`. Expected: build failure on the missing members.

- [ ] **Step 3: Implement `ShowDocument+Groups.swift`** to the interfaces above. `channelsInDisplayOrder` is `groups.flatMap { channels(inGroup: $0.id) } + channels(inGroup: nil)`. Normalising sets `channels = channelsInDisplayOrder` after clearing dangling IDs. Safe now, because of Task 1.

- [ ] **Step 4: Run the tests to make sure they pass**: `swift test`. Expected: all pass, including the existing legacy-format tests.

- [ ] **Step 5: Commit**: `Add channel group editing and display order to ShowDocument`.

---

### Task 3: Selecting a group

**Files:**
- Modify: `Packages/WilcoCore/Sources/WilcoCore/Model/SidebarItem.swift`
- Modify: `Wilco/AppModel.swift`
- Test: `Packages/WilcoCore/Tests/WilcoCoreTests/ChannelEditingTests.swift` (`SidebarItemTests`)

**Interfaces:**
- Consumes: `ShowDocument.group(id:)`, `deleteGroup(id:)`, `addGroup()` (Task 2).
- Produces:
  - `SidebarItem.group(UUID)`, stored as `"group:<UUID>"`. `validated(in:)` returns `.combined` for a missing group.
  - `AppModel.addGroup()`: creates the group, selects it, and sets `AppModel.groupBeingRenamed: ChannelGroup.ID?` so the sidebar starts inline rename.
  - `AppModel.deleteGroup(_ id: ChannelGroup.ID)`: if `selection == .group(id)`, set `.combined` **before** deleting. No confirmation.

- [ ] **Step 1: Write the failing tests**: extend the round-trip loop in `SidebarItemTests` with `.group(id)`. Add:

```swift
@Test func selectionOfDeletedGroupFallsBackToCombined() {
    var show = ShowDocument()
    let group = show.addGroup()
    let item = SidebarItem.group(group.id)
    #expect(item.validated(in: show) == item)
    show.deleteGroup(id: group.id)
    #expect(item.validated(in: show) == .combined)
}
@Test func channelSelectionSurvivesDeletingItsGroup() {
    var show = ShowDocument()
    let group = show.addGroup()
    let channel = show.addChannel()
    show.assignChannel(channel.id, toGroup: group.id)
    show.deleteGroup(id: group.id)
    #expect(SidebarItem.channel(channel.id).validated(in: show) == .channel(channel.id))
}
```

- [ ] **Step 2: Run to make sure they fail.** `swift test --filter SidebarItemTests`

- [ ] **Step 3: Implement the `SidebarItem` changes.** Then add the `AppModel` members listed above, and add `case .group` to every `switch` over `SidebarItem` that no longer compiles. `MainWindowView.DetailView` and `InspectorView` can route `.group` to the Combined transcript and `ShowInspector` for now. Tasks 4 and 5 replace these.

- [ ] **Step 4: Run tests and build the app.** Both green.

- [ ] **Step 5: Commit**: `Add group selection to the sidebar model`.

---

### Task 4: Channel scope: filter the transcript to a group

**Files:**
- Create: `Packages/WilcoCore/Sources/WilcoCore/Model/ChannelScope.swift`
- Create: `Packages/WilcoCore/Tests/WilcoCoreTests/ChannelScopeTests.swift`
- Modify: `Wilco/Transcript/TranscriptView.swift` (`TranscriptView`, `LiveHeader`)
- Modify: `Wilco/AppModel.swift` (chip state)
- Modify: `Wilco/MainWindowView.swift` (`DetailView`)
- Modify: `Wilco/Transcript/ChannelMatrixView.swift` (call site only: `TranscriptView(scope: .channel(id), …)`)

**Interfaces:**
- Produces:
  - `public enum ChannelScope: Hashable, Sendable { case all, channel(UUID), group(UUID) }`
  - `func channels(in show: ShowDocument) -> [ChannelConfig]`: in display order. `.all` gives every channel, `.channel` gives that one (or none), `.group` gives `show.channels(inGroup:)` (none for a missing group).
  - `func includes(_ channelID: UUID?, in show: ShowDocument, narrowedTo chips: Set<UUID>) -> Bool`. A `nil` channel ID (a marker with no channel) is included for `.all` and `.group` and excluded for `.channel`, matching today's marker rule. `chips` is ignored for `.channel`, and empty chips mean no narrowing.
  - `TranscriptView(scope: ChannelScope, compact: Bool = false, fontSize: Double? = nil)` replaces `channelID:`.
  - `AppModel.chipFilters: [ChannelScope: Set<ChannelConfig.ID>]` replaces `combinedChannelFilter`. Each scope keeps its own chips.

- [ ] **Step 1: Write the failing tests** (`@Suite("Channel scope")`):

```swift
@Test func groupScopeIncludesOnlyItsChannels()      // c,d in Radios; a not
@Test func groupChipsNarrowWithinTheGroup()          // chips [c] → c in, d out
@Test func chipsOutsideTheGroupDoNotWidenIt()        // chips [a] with group Radios → a still out
@Test func emptyGroupHasNoChannels()                 // addGroup() → channels(in:) == []
@Test func missingGroupHasNoChannels()
@Test func channelScopeIgnoresChips()
@Test func channellessMarkersShowInAllAndGroupButNotChannel()
@Test func allScopeFollowsDisplayOrder()             // == show.channelsInDisplayOrder
```

Each test has one or two `#expect`s, built on the Task 2 `makeShow()` fixture. Move that helper to a shared `Fixtures+Groups.swift` in the test target if both suites need it.

- [ ] **Step 2: Run to make sure they fail.**

- [ ] **Step 3: Implement `ChannelScope`.**

- [ ] **Step 4: Switch `TranscriptView` and `LiveHeader` to the scope.**
  - `settledItems` and `volatileItems` use `scope.includes(…, narrowedTo: model.chipFilters[scope] ?? [])`.
  - Rows show the channel tag unless the scope is `.channel`.
  - Header title: show name (`.all`), channel label (`.channel`), or group `symbol` and name (`.group`).
  - Chips appear for `.all` and `.group`, listing `scope.channels(in:)`.
  - Stats for `.group` match `.all` (messages, markers, channels) and count only in-scope lines.
  - Empty state is unchanged. An empty group shows "Listening" or "Not Capturing" like everything else.
  - `DetailView` routes `.combined → .all`, `.channel(id) → .channel(id)` and `.group(id) → .group(id)`.

- [ ] **Step 5: Run tests and build.** Both green. The by-hand check of a group view happens in Task 5, once folders can be selected.

- [ ] **Step 6: Commit**: `Filter the transcript by group through ChannelScope`.

---

### Task 5: Sidebar folders, group inspector and context menus

**Files:**
- Modify: `Wilco/Sidebar/SidebarView.swift`
- Create: `Wilco/Sidebar/GroupRow.swift`
- Create: `Wilco/Inspector/GroupInspector.swift`
- Modify: `Wilco/Inspector/InspectorView.swift`, `Wilco/Inspector/ChannelInspector.swift`
- Modify: `Wilco/Appearance/LookAndFeel.swift`

**Interfaces:**
- Consumes: Task 2 operations; Task 3 `AppModel.addGroup()`, `deleteGroup(_:)`, `groupBeingRenamed`.
- Produces: `LookAndFeel.collapsedGroups: Set<UUID>`, persisted under the defaults key `sidebar.collapsedGroups` as an array of UUID strings. Don't add it to the 0.2.0 legacy-import list.

- [ ] **Step 1: Build the outline.** In the Channels section, `ForEach(model.document.groups)` gives a `DisclosureGroup` per group:
  - its label is a `GroupRow` showing the symbol, name and channel count, tagged `.group(id)`;
  - its children are `ChannelRow`s for `channels(inGroup: id)` with `.onMove` → `moveChannels(inGroup: id, …)`;
  - expansion is bound to `look.collapsedGroups`.

  After the folders, add the ungrouped `ChannelRow`s with `.onMove` → `moveChannels(inGroup: nil, …)`. `ForEach(groups).onMove` → `moveGroups`. When a group is collapsed, `GroupRow` shows a `LevelMeter` at the **maximum** of its channels' `model.meters` (hidden when none is metering).

- [ ] **Step 2: Add creation, rename and the menus.**
  - **New Group** button (`folder.badge.plus`, help "Add a group") beside **Add Channel** calls `model.addGroup()`.
  - `GroupRow` shows a `TextField` while `model.groupBeingRenamed == group.id`. On submit it calls `renameGroup` and clears the flag.
  - Group context menu: **Rename** (sets the flag), **Change Icon** (a submenu of the symbols below), and **Delete Group** (`role: .destructive`, `model.deleteGroup`).
  - `onDeleteCommand` deletes a selected group without asking, and keeps today's confirmation for channels.
  - Channel context menu gains a **Move to Group** submenu: **None** plus each group, calling `assignChannel`. *(Builder addition: a dependable path that doesn't need drag and drop.)*

- [ ] **Step 3: Add the inspectors.**
  - `InspectorView` routes `.group(id)` to `GroupInspector`. It shows a Name `TextField` (renameGroup), a Symbol picker over `["folder", "antenna.radiowaves.left.and.right", "rectangle.3.group", "theatermasks", "video", "lightbulb", "music.mic", "headphones"]`, and a read-only list of member channels.
  - In `ChannelInspector`, the Group picker is always shown. Its options are None, the groups, a divider, then **New Group…**, which creates a group and assigns this channel to it. Changes go through `assignChannel`, not by setting `groupID` directly, so the order stays normalised.

- [ ] **Step 4: Build and check by hand.** Click a folder and confirm only its channels' lines show, with its chips narrowing further. Create, rename, re-icon and delete groups. Use Move to Group. Collapse a folder, quit and relaunch, and check it's still collapsed. Delete a selected group and check the selection goes to Combined.

- [ ] **Step 5: Commit**: `Show groups as folders in the sidebar`.

---

### Task 6: Drag channels into folders

**Files:**
- Modify: `Wilco/Sidebar/SidebarView.swift`, `Wilco/Sidebar/GroupRow.swift`

**Interfaces:**
- Consumes: `assignChannel(_:toGroup:)`, `moveGroups`, `moveChannels(inGroup:…)`.

- [ ] **Step 1: Make channels draggable onto folders.**
  - Channel rows become draggable as their ID, for example `.draggable(channel.id.uuidString)`.
  - `GroupRow` gets `.dropDestination(for: String.self)` → `assignChannel(id, toGroup: group.id)`, highlighting while targeted.
  - Dropping on the ungrouped area ungroups the channel. Use a drop target on the "Channels" section header, or on the ungrouped rows.
- [ ] **Step 2: Check on macOS 15 behaviour that reorder (`onMove`) and drop-onto-folder coexist.** If SwiftUI's `List` won't let a row both move and drop, drive the sidebar's drag and drop with `onInsert` on each section instead. Inserting into a folder's section is then "assign + move". Keep the Task 5 menu paths either way. Note in the commit message which approach you used.
- [ ] **Step 3: Check by hand.**
  - Drag a channel into a folder, from one folder to another, and out to ungrouped.
  - Reorder inside a folder, and reorder the folders themselves.
  - **During a running capture, do all of the above and confirm no capture restart.** Meters keep moving, and the Activity or status bar shows no reconnect.
- [ ] **Step 4: Commit**: `Drag channels into and out of sidebar folders`.

---

### Task 7: Matrix by channel or by group

**Files:**
- Create: `Packages/WilcoCore/Sources/WilcoCore/Appearance/MatrixColumns.swift`
- Test: `Packages/WilcoCore/Tests/WilcoCoreTests/AppearanceTests.swift`
- Modify: `Wilco/Transcript/ChannelMatrixView.swift`, `Wilco/Appearance/LookAndFeel.swift`

**Interfaces:**
- Produces:
  - `public enum MatrixMode: String, CaseIterable, Sendable { case channels, groups }`, persisted by `LookAndFeel.matrixMode` under the key `matrix.mode`, defaulting to `.channels`.
  - `public enum MatrixColumn: Identifiable, Equatable { case channel(ChannelConfig), group(ChannelGroup, channelCount: Int) }`. Its `id` is the channel's or group's UUID, and it has `var scope: ChannelScope`.
  - `ShowDocument.matrixColumns(_ mode: MatrixMode) -> [MatrixColumn]`. For `.channels` it is every channel in display order. For `.groups` it is each non-empty group in folder order, then each ungrouped channel.

- [ ] **Step 1: Write the failing tests** (`@Suite("Matrix columns")`):

```swift
@Test func channelModeIsDisplayOrder()   // ids == channelsInDisplayOrder ids
@Test func groupModeIsGroupsThenUngrouped() {
    #expect(show.matrixColumns(.groups).map(\.id) == [radios.id, stage.id, b.id])
}
@Test func emptyGroupsGetNoColumn()
```

- [ ] **Step 2: Run to make sure they fail; Step 3: implement.**

- [ ] **Step 4: Update the view.**
  - Add a toolbar `Picker("Show", selection: $look.matrixMode)` with `.segmented` style, labelled "Channels" and "Groups".
  - `ForEach(model.document.matrixColumns(look.matrixMode))` renders the existing column, generalised from `channel:` to `column: MatrixColumn`.
  - The header shows the channel label with its meter, or the group symbol, name and "N channels" (singular for 1).
  - The body is `TranscriptView(scope: column.scope, compact: true, fontSize:)`.
  - Width, collapse and font size are keyed by `column.id`. Fit and Expand All use the visible columns' IDs.

- [ ] **Step 5: Run tests, build, and check by hand.** Switch modes. Resize and collapse a group column, then relaunch and confirm it's remembered. Check that an ungrouped channel shows as its own column in Groups mode.

- [ ] **Step 6: Commit**: `Matrix: show columns by channel or by group`.

---

### Task 8: Group chips in the report and HTML export

**Files:**
- Modify: `Packages/WilcoCore/Sources/WilcoCore/Report/ShowReport.swift` (`ShowReport`, `ShowReportBuilder.build`)
- Modify: `Packages/WilcoCore/Sources/WilcoCore/Report/ShowReportHTML.swift` (`channelChips`, `script`)
- Modify: `Wilco/Report/ReportModel.swift`, `Wilco/Report/ShowReportWindow.swift` (`ChipFilters`)
- Test: `Packages/WilcoCore/Tests/WilcoCoreTests/ShowReportTests.swift`

**Interfaces:**
- Produces:
  - `ShowReport.Group: Identifiable, Sendable { id: UUID, name: String, symbol: String, channelIDs: [UUID] }` and `ShowReport.groups: [Group]`. Built from the show's **current** groups in folder order. `channelIDs` holds only members with messages in this session, and groups left with none are omitted.
  - `ShowReport.Group.isOn(in filter: Set<UUID>) -> Bool`: true when all of its channels are in the filter.
  - `ShowReport.Group.toggled(_ filter: Set<UUID>) -> Set<UUID>`: removes all of its channels if `isOn`, otherwise adds them all.
  - `ReportModel.toggleGroup(_ group: ShowReport.Group)`

- [ ] **Step 1: Write the failing tests** (in the existing report suite, using in-memory segments the way current tests build them, not the live-session suite):

```swift
@Test func reportGroupsFollowCurrentShowAndSkipSilentChannels()
    // Radios = c (spoke), d (silent); Stage = a (silent) → groups == [Radios: [c]]
@Test func groupChipTogglesAllItsChannels() {
    #expect(group.toggled([]) == [c, d])
    #expect(group.toggled([c, d, a]) == [a])
    #expect(group.toggled([c]) == [c, d])        // partly on → turns all on
}
@Test func htmlHasGroupChipsWithMemberIDsAndEscapesNames() {
    // group named `Rad<i>os & "Co"`
    #expect(html.contains(#"data-group="\#(c),\#(d)""#))
    #expect(html.contains("Rad&lt;i&gt;os &amp; &quot;Co&quot;"))
    #expect(!html.contains("Rad<i>os"))
}
```

- [ ] **Step 2: Run to make sure they fail; Step 3: implement the model and builder.**

- [ ] **Step 4: Add HTML group chips** after "All channels". Use `chip(name, count: nil, tint: .gray, attributes: #"data-group="<comma-separated ids>""#, on: false)`, with the name prefixed by a folder glyph (`📁 `). In the `script`, clicking a `[data-group]` chip toggles the group's ids in `chs` (all off if all on, else all on). The class refresh marks a group chip on when every one of its IDs is in `chs`. Channel chips behave as now.

- [ ] **Step 5: Update the report window.** `ChipFilters` puts group chips after "All channels" (symbol and name, gray, no count) and calls `model.toggleGroup`, with `isOn` from `group.isOn(in: model.channelFilter)`. Run of show, chat log and the Channels tab already follow `channelFilter`.

- [ ] **Step 6: Run tests, build, and check by hand.** In the report, click a group chip, then a channel chip, then the group chip again. Export HTML, open it in a browser, and repeat.

- [ ] **Step 7: Commit**: `Report and HTML export: filter by group`.

---

### Task 9: Whole-feature verification

- [ ] **Step 1:** Run `swift test` and `WILCO_ASR_TESTS=1 swift test` in `Packages/WilcoCore`, then the app `xcodebuild`. All must be green.
- [ ] **Step 2:** Open a 0.2.0 show backup and confirm it loads with no groups and an unchanged channel order. Then make groups, quit, relaunch and confirm they persist.
- [ ] **Step 3:** Hand the user the app-testing checklist from the spec's "Done means". Record the feature in `docs/PROGRESS.md` as "built, awaiting user test" until they confirm it, and update the README status table.
