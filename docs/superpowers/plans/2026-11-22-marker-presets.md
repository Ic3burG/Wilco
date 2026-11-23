# Marker Presets Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Save a show's marker lists as named presets in an app-wide folder, then load, rename or delete them from the Markers tab.

**Architecture:** `MarkerPresetStore` in WilcoCore stores one `‹UUID›.json` file per `MarkerPreset` in `DataLocations.markerPresets`, following `ConfigurationStore`. The app adds a Presets menu and two small sheets to `MarkerSettingsView`.

**Tech Stack:** Swift 6, SwiftUI (macOS 15 target), Swift Testing.

**Spec:** `docs/superpowers/specs/2026-11-22-marker-presets-design.md`. This builds on the `editable-markers` branch (`MarkerSettings`, `ShowDocument.markers`, `MarkerSettingsView`).

## Global Constraints

- Folder: `~/Library/Application Support/Wilco/Presets/Markers/`, one `‹UUID›.json` per preset. The UUID is the identity, so renaming never moves a file.
- Preset names are unique ignoring case. Unreadable files are skipped and left alone.
- Loading replaces the show's whole marker set with a copy. There's no merging, and presets are only ever read on load.
- Don't name the reference app. CI uses Xcode 26.6, so no macOS 27-only API without a guard. Swift 6 with no new warnings.
- Package tests: `cd Packages/WilcoCore && swift test`. App build: `xcodebuild build -project Wilco.xcodeproj -scheme Wilco -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY=""`.

## Review Focus

1. **The presets folder doesn't exist yet** (first use). `list()` returns `[]`, and `save` creates the folder. Test in Task 1.
2. **A name differing only in case or surrounding spaces** ("concert " vs "Concert") counts as the same preset. Saving replaces it and keeps its ID. Test in Task 1.
3. **A preset file written by a newer build** (unknown label category, extra keys) still loads, with that label dropped. Test in Task 1.
4. **A stray non-UUID file or a corrupt `.json` in the folder** is skipped, not deleted, and `list()` still returns the rest. Test in Task 1.
5. **Loading a preset, then editing the show,** leaves the preset file unchanged. This holds by design because loading copies a value. Task 2 checks it by hand in the app.

---

### Task 1: `MarkerPresetStore`

**Files:**
- Create: `Packages/WilcoCore/Sources/WilcoCore/Persistence/MarkerPresetStore.swift`
- Modify: `Packages/WilcoCore/Sources/WilcoCore/Persistence/DataLocations.swift` (add `markerPresets`)
- Test: `Packages/WilcoCore/Tests/WilcoCoreTests/MarkerPresetStoreTests.swift`

**Interfaces:**
- Produces:
  - `public struct MarkerPreset: Codable, Equatable, Identifiable, Sendable { id: UUID; name: String; markers: MarkerSettings }`. `id` isn't encoded; it comes from the file name. Missing `name` decodes as `"Untitled Preset"`; missing `markers` decodes as `.standard`.
  - `public struct MarkerPresetStore: Sendable` with `init(directory: URL = DataLocations.markerPresets)` and:
    - `func list() -> [MarkerPreset]`, sorted with `localizedStandardCompare`.
    - `func preset(_ id: UUID) throws -> MarkerPreset`, throwing `ConfigurationError.notFound`.
    - `func existing(named: String) -> MarkerPreset?`, comparing trimmed names ignoring case.
    - `@discardableResult func save(name: String, markers: MarkerSettings) throws -> MarkerPreset`, which trims the name, throws `.emptyName`, and reuses an existing preset's ID and file when the name is taken.
    - `@discardableResult func rename(_ id: UUID, to name: String) throws -> MarkerPreset`, throwing `.emptyName`, `.nameTaken(otherName)` or `.notFound`.
    - `func delete(_ id: UUID) throws`, throwing `.notFound`.
  - `DataLocations.markerPresets: URL`, which is `root/Presets/Markers`.

- [ ] **Step 1: Write the failing tests** (`@Suite("Marker preset store")`, with a temp directory per test as in `ConfigurationStoreTests`)

```swift
@Test func listIsEmptyBeforeTheFolderExists() { #expect(store.list().isEmpty) }
@Test func saveThenListByName() throws {
    var concert = MarkerSettings.standard; concert.departments.append("rigging")
    try store.save(name: "Theatre", markers: .standard)
    try store.save(name: "Concert", markers: concert)
    #expect(store.list().map(\.name) == ["Concert", "Theatre"])
    #expect(store.list().first?.markers == concert)
}
@Test func savingAnExistingNameReplacesItAndKeepsItsID() throws {
    let first = try store.save(name: "Concert", markers: .standard)
    var changed = MarkerSettings.standard; changed.countdownEnabled = false
    let second = try store.save(name: " concert ", markers: changed)
    #expect(second.id == first.id)
    #expect(store.list().count == 1)
    #expect(try store.preset(first.id).markers == changed)
    #expect(try store.preset(first.id).name == "Concert")   // keeps the existing name's spelling
}
@Test func emptyNameIsRefused() { #expect(throws: ConfigurationError.emptyName) { try store.save(name: "  ", markers: .standard) } }
@Test func renameRefusesTakenAndEmptyNames() throws {
    let a = try store.save(name: "Concert", markers: .standard)
    try store.save(name: "Theatre", markers: .standard)
    #expect(throws: ConfigurationError.nameTaken("Theatre")) { try store.rename(a.id, to: "theatre") }
    #expect(throws: ConfigurationError.emptyName) { try store.rename(a.id, to: "") }
    try store.rename(a.id, to: "Arena")
    #expect(store.list().map(\.name) == ["Arena", "Theatre"])
    #expect(try store.preset(a.id).name == "Arena")
}
@Test func renamingToItsOwnNameInAnotherCaseIsAllowed() throws {
    let a = try store.save(name: "concert", markers: .standard)
    #expect(try store.rename(a.id, to: "Concert").name == "Concert")
}
@Test func deleteRemovesAndMissingThrows() throws {
    let a = try store.save(name: "Concert", markers: .standard)
    try store.delete(a.id)
    #expect(store.list().isEmpty)
    #expect(throws: ConfigurationError.notFound) { try store.delete(a.id) }
}
@Test func strayAndCorruptFilesAreSkippedAndKept() throws {
    try store.save(name: "Concert", markers: .standard)
    let stray = directory.appending(path: "notes.json"), corrupt = directory.appending(path: "\(UUID()).json")
    try Data("{}".utf8).write(to: stray); try Data("not json".utf8).write(to: corrupt)
    #expect(store.list().map(\.name) == ["Concert"])
    #expect(FileManager.default.fileExists(atPath: stray.path) && FileManager.default.fileExists(atPath: corrupt.path))
}
@Test func presetFromANewerBuildStillLoads() throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let id = UUID()
    let json = #"{"name":"Future","extra":1,"markers":{"labels":[{"id":"\#(UUID())","category":"lasers","name":"X","isEnabled":true,"phrases":["x"]}],"departments":["pyro"]}}"#
    try Data(json.utf8).write(to: directory.appending(path: "\(id).json"))
    let preset = try store.preset(id)
    #expect(preset.name == "Future" && preset.markers.labels.isEmpty && preset.markers.departments == ["pyro"])
}
```

- [ ] **Step 2: Run to verify failure**

Run: `cd Packages/WilcoCore && swift test --filter MarkerPresetStoreTests`
Expected: compile failure, `MarkerPresetStore` not found.

- [ ] **Step 3: Implement.**
  - Follow `ConfigurationStore`'s layout and its `.atomic` writes.
  - The file extension is `json`. Use `WilcoJSON.encoder()` and `WilcoJSON.decoder()`.
  - `list()` keeps only files whose names are UUIDs and that decode, setting each preset's `id` from its file name.
  - In `save`, when `existing(named:)` finds a match, write under its ID and keep its name.

- [ ] **Step 4: Run to verify pass**

Run: `cd Packages/WilcoCore && swift test`
Expected: all pass.

- [ ] **Step 5: Commit** with the message "Marker presets: a store for named marker sets".

---

### Task 2: Presets menu in the Markers tab

**Files:**
- Create: `Wilco/Settings/MarkerPresetsMenu.swift` (the menu, the save sheet and the manage sheet)
- Modify: `Wilco/Settings/MarkerSettingsView.swift` (put the menu in the bottom bar before "Restore Defaults…")

**Interfaces:**
- Consumes: `MarkerPresetStore`, `MarkerPreset`, `ConfigurationError` (Task 1); `model.document.markers` / `markerSettings`.
- Produces: `struct MarkerPresetsMenu: View`, used as `MarkerPresetsMenu()` and reading `AppModel` from the environment.

- [ ] **Step 1: Build the menu.**
  - Use `Menu("Presets")` with `.fixedSize()`.
  - Items, in order:
    - "Save as Preset…", which opens the save sheet;
    - a `Divider`;
    - one `Button(preset.name)` per preset in `store.list()`, or a disabled "No Presets" when there are none;
    - a `Divider`;
    - "Manage Presets…", disabled when there are no presets.
  - Re-read the list in the menu's `onAppear`, and again whenever a sheet closes.
- [ ] **Step 2: Load a preset.** Choosing a preset when `model.document.markers == nil` sets `model.document.markers = preset.markers` straight away. Otherwise show a `confirmationDialog`: "Replace this show's markers with “\(name)”?", with a "Replace" button. Load errors appear in an `.alert("Wilco", …)` with the error text, as `ConfigurationsWindow` does.
- [ ] **Step 3: Build the save sheet.** A `Form` with a Name `TextField`, titled "Save Markers as Preset", 360 wide. Cancel and Save go in the toolbar, as in `RenameSheet`, and Save is disabled while the name is blank.
  - If `store.existing(named:)` finds a preset, Save shows a `confirmationDialog` "Replace the “\(existing.name)” preset?" with "Replace". Otherwise it saves `model.document.markerSettings` straight away.
  - The sheet closes after saving.
- [ ] **Step 4: Build the manage sheet.** A bordered `List` of presets, about 360×300, titled "Marker Presets".
  - Each row has its name, a Rename button that opens a rename field sheet, and a Delete button.
  - Delete confirms first: "Delete the “\(name)” preset?". It says nothing about shows, because shows keep their own copies.
  - A `nameTaken` error from rename shows "A preset named “X” already exists."
  - Done closes the sheet.
- [ ] **Step 5: Build the app.** Run the app build command. Expected: `** BUILD SUCCEEDED **` with no new warnings.
- [ ] **Step 6: Commit** with the message "Presets menu in Settings › Markers".

---

### Task 3: Docs

**Files:** Modify `docs/SPEC.md` (the §8 markers paragraph, plus the data-locations table that lists `Configurations/‹UUID›.wilco`).

- [ ] **Step 1: Add to §8.** Marker presets: Settings › Markers › Presets saves or loads named marker sets. Loading replaces the show's markers with a copy, and confirms first if the show has its own. Saving under an existing name, ignoring case, replaces that preset after confirming.
- [ ] **Step 2: Add a data-locations row.** `Presets/Markers/‹UUID›.json`: `{ name, markers }`, one per preset. New in the rebuild.
- [ ] **Step 3: Check and commit.** Run `cd Packages/WilcoCore && swift test`, expect a pass, then commit with "Spec: marker presets".

Report the feature as "tested", not "verified", until the user has tried it in the app.
