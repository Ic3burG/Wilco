# Configurations Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Saved, named show setups that load in one action, with snapshot semantics (Save / Save As New / Revert), a title menu, a Configurations window, and `.wilco` import/export.

**Architecture:** `Current.wilco` stays the autosaved working copy. A new `ConfigurationStore` in WilcoCore keeps one `‹UUID›.wilco` per configuration in `Application Support/Wilco/Configurations/`. Pure rules (status, load decision, name validation) live in WilcoCore with tests. `AppModel` holds the loaded ID plus the saved snapshot and runs the actions. The UI is a `.toolbarTitleMenu`, File menu commands and a `Window` scene.

**Tech Stack:** Swift 6 (strict concurrency), SwiftUI on macOS 15+, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-11-12-configurations-design.md`

## Global Constraints

- `ShowDocument` gains **no new fields**. Configuration files are plain `ShowDocument` JSON written with `WilcoJSON.encoder()` and read with `WilcoJSON.decoder()`.
- All file writes are atomic (`Data.write(to:options: .atomic)`).
- Storage folder: `DataLocations.root/Configurations/`; filename `‹UUID().uuidString›.wilco`.
- Loaded configuration ID is stored in `UserDefaults` key `configurations.loaded`.
- Names: trimmed, non-empty, unique case-insensitively. Collisions get `" 2"`, `" 3"`, and so on; copies get `" copy"`.
- Load and Revert are refused while capturing. Save is allowed while capturing.
- Deployment target macOS 15; CI runs Xcode 26.6, so use no macOS 27-only API.
- Tests use Swift Testing (`@Suite`, `@Test`, `#expect`), temporary directories, as in `ShowStoreTests`.
- App build command: `xcodebuild build -project Wilco.xcodeproj -scheme Wilco -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY=""`. It must report `** BUILD SUCCEEDED **` with no new warnings.

## Review Focus

1. **Inspector rename clash:** the user renames the show in the inspector to another configuration's name, then presses Save. Expect Save to be refused with "Another configuration is already called “X”." and nothing written. Tested in Task 3 (`saveNameCheck`).
2. **Imported file with a blank name:** `"name": "  "`. Expect it to import as "New Show" (uniqued), not as an empty row. Tested in Task 2.
3. **Loaded configuration's file deleted behind Wilco's back:** expect status `.notSaved`, title "‹name› — Not Saved", and Save acting as Save As New. Tested in Task 3 (`status`) and wired in Task 4.
4. **Junk in the Configurations folder** (an unreadable `.wilco` file, a non-UUID filename, `.DS_Store`): expect `list()` to skip it without crashing and not to delete it. Tested in Task 1.
5. **Load reached while capturing** (double-click in the Configurations window): expect a refusal message and the show unchanged. Tested in Task 3 (`loadDecision`).

---

### Task 1: `ConfigurationStore` core

**Files:**
- Create: `Packages/WilcoCore/Sources/WilcoCore/Persistence/ConfigurationStore.swift`
- Modify: `Packages/WilcoCore/Sources/WilcoCore/Persistence/DataLocations.swift` (add `configurations`)
- Test: `Packages/WilcoCore/Tests/WilcoCoreTests/ConfigurationStoreTests.swift`

**Interfaces:**
- Produces:
  - `DataLocations.configurations: URL` (`root/Configurations`, directory)
  - `public struct ConfigurationSummary: Identifiable, Equatable, Sendable { public let id: UUID; public let name: String; public let channelCount: Int; public let savedAt: Date }`. `savedAt` is the file's modification date.
  - `public enum ConfigurationError: Error, Equatable { case emptyName, nameTaken(String), notFound }`
  - `public struct ConfigurationStore: Sendable` with:
    - `init(directory: URL = DataLocations.configurations)`
    - `func list() -> [ConfigurationSummary]`: sorted by `name.localizedStandardCompare`; skips files that don't decode or whose stem isn't a UUID
    - `func document(_ id: UUID) throws -> ShowDocument`: throws `.notFound` if missing
    - `func exists(_ id: UUID) -> Bool`
    - `func write(_ document: ShowDocument, id: UUID) throws`: overwrites; creates the folder
    - `func create(_ document: ShowDocument) throws -> UUID`: names it `uniqueName(document.name)`, writes it, returns the new ID
    - `func rename(_ id: UUID, to name: String) throws -> ShowDocument`: trims; `.emptyName` / `.nameTaken`; returns the renamed document
    - `func duplicate(_ id: UUID) throws -> UUID`: copy named `uniqueName("‹name› copy")`
    - `func delete(_ id: UUID) throws`
    - `func uniqueName(_ proposed: String, excluding: UUID? = nil) -> String`: trims; empty becomes `"New Show"`; on a case-insensitive clash appends `" 2"`, `" 3"`, and so on

- [ ] **Step 1: Write the failing tests** in `ConfigurationStoreTests` (temporary directory per test, like `ShowStoreTests`):
  - `createListsByNameWithChannelCount`: create "Theatre" (2 channels) and "Arena" (0) → `list().map(\.name) == ["Arena", "Theatre"]`, `channelCount` of Theatre `== 2`
  - `createUniquesNames`: create "Arena" twice and "arena" once → names `["Arena", "Arena 2", "arena 3"]` (sorted by `localizedStandardCompare`; assert as a `Set` if the order is unstable)
  - `writeOverwritesAndDocumentReads`: create, mutate a channel name, `write(_:id:)` → `document(id)` equals the mutated document
  - `renameRejectsEmptyAndTaken`: `rename(id, to: "  ")` throws `.emptyName`; renaming to the other's name in a different case throws `.nameTaken("Arena")`; `rename(id, to: " Stadium ")` returns name "Stadium" and persists it
  - `renameToOwnNameDifferentCaseIsAllowed`: "Arena" → "ARENA" succeeds
  - `duplicateAddsCopy`: duplicate "Arena" twice → names include "Arena copy" and "Arena copy 2"; documents equal apart from `name`
  - `deleteRemovesFile`: then `exists(id) == false`, `document(id)` throws `.notFound`
  - `listSkipsJunk`: write `"{ nope"` to `‹UUID›.wilco`, a valid show to `notauuid.wilco`, and an empty `.DS_Store` → `list()` is empty and all three files still exist

- [ ] **Step 2: Run** `cd Packages/WilcoCore && swift test --filter ConfigurationStoreTests`. Expected: build failure (`ConfigurationStore` undefined).

- [ ] **Step 3: Implement** `ConfigurationStore` and `DataLocations.configurations`. Use `contentsOfDirectory(at:includingPropertiesForKeys: [.contentModificationDateKey])`, and `WilcoJSON` for coding.

- [ ] **Step 4: Run** the same filter. Expected: all pass. Then run the full `swift test`. Expected: all pass.

- [ ] **Step 5: Commit** `Configurations: store for saved show setups`

### Task 2: Import, export and first-run migration

**Files:**
- Modify: `Packages/WilcoCore/Sources/WilcoCore/Persistence/ConfigurationStore.swift`
- Test: `Packages/WilcoCore/Tests/WilcoCoreTests/ConfigurationStoreTests.swift`

**Interfaces:**
- Consumes: Task 1's store.
- Produces:
  - `public struct ConfigurationImport: Equatable, Sendable { public var imported: [UUID]; public var failed: [URL] }`
  - `func importFiles(_ urls: [URL]) -> ConfigurationImport`: decodes each file; a decode or read failure goes in `failed`, and the rest import via `create`
  - `func export(_ id: UUID, to url: URL) throws`: writes the saved document with `WilcoJSON.encoder()`
  - `func migrateIfEmpty(from current: ShowDocument) throws -> UUID?`: if the folder has no readable configurations, creates one from `current` (keeping its name) and returns its ID; otherwise `nil`

- [ ] **Step 1: Write the failing tests**
  - `importsFormatV1Fixture`: import the `show-v1.wilco` fixture (load via `Bundle.module.url(forResource: "Fixtures/show-v1.wilco", withExtension: nil)`, as `FileFormatTests` does) → one imported; `document(id)` equals `WilcoJSON.decoder().decode(ShowDocument.self, from: fixtureData)`
  - `importKeepsGoodFilesAndReportsBad`: one good file and one `"{ nope"` file → `imported.count == 1`, `failed == [badURL]`
  - `importBlankNameBecomesNewShow`: file `{"name":"  "}` → the imported name is "New Show"
  - `importClashGetsNumber`: existing "Arena", import a file named "Arena" → "Arena 2"
  - `exportRoundTrips`: export to a temporary URL and decode → equals `document(id)`
  - `migrateCreatesFromCurrentOnce`: `migrateIfEmpty(from: ShowDocument(name: "Tour"))` returns an ID named "Tour"; a second call returns `nil` and `list().count == 1`
  - `migrateIgnoresJunkOnlyFolder`: the folder holds only an unreadable `‹UUID›.wilco` → migration still creates one

- [ ] **Step 2: Run** `swift test --filter ConfigurationStoreTests`. Expected: build failure on the new API.

- [ ] **Step 3: Implement** the three methods.

- [ ] **Step 4: Run** the filter, then the full `swift test`. Expected: all pass.

- [ ] **Step 5: Commit** `Configurations: import, export and first-run migration`

### Task 3: Configuration rules (pure logic)

**Files:**
- Create: `Packages/WilcoCore/Sources/WilcoCore/Persistence/ConfigurationRules.swift`
- Test: `Packages/WilcoCore/Tests/WilcoCoreTests/ConfigurationRulesTests.swift`

**Interfaces:**
- Produces (`public enum ConfigurationRules`):
  - `enum Status: Equatable, Sendable { case saved, edited, notSaved }`
  - `static func status(working: ShowDocument, saved: ShowDocument?) -> Status`: `saved == nil` gives `.notSaved`; equal gives `.saved`; otherwise `.edited`
  - `enum LoadDecision: Equatable, Sendable { case refuseWhileCapturing, alreadyLoaded, askToSaveFirst, load }`
  - `static func loadDecision(target: UUID, loaded: UUID?, status: Status, isCapturing: Bool) -> LoadDecision`, checked in this order: capturing → refuse; `target == loaded` → alreadyLoaded; `status == .edited` → askToSaveFirst; else load. (`.notSaved` also asks, because those edits exist nowhere else.)
  - `static func saveNameCheck(name: String, loaded: UUID?, in summaries: [ConfigurationSummary]) -> ConfigurationError?`: trims; empty gives `.emptyName`; another ID with the same name (case-insensitive) gives `.nameTaken(existingName)`; else `nil`
  - `static func titleSuffix(_ status: Status) -> String`: `""`, `" — Edited"`, `" — Not Saved"`

- [ ] **Step 1: Write the failing tests**
  - `statusCases`: nil saved → `.notSaved`; equal → `.saved`; a changed channel → `.edited`; changed then changed back → `.saved`
  - `loadDecisionOrder`: capturing beats everything (even the same ID) → `.refuseWhileCapturing`; same ID → `.alreadyLoaded`; edited → `.askToSaveFirst`; notSaved → `.askToSaveFirst`; saved → `.load`
  - `saveNameCheck`: own name passes; another's name in a different case → `.nameTaken("Arena")`; blank → `.emptyName`
  - `titleSuffix` exact strings as above

- [ ] **Step 2: Run** `swift test --filter ConfigurationRulesTests`. Expected: build failure.

- [ ] **Step 3: Implement.**

- [ ] **Step 4: Run** the filter, then the full `swift test`. Expected: all pass.

- [ ] **Step 5: Commit** `Configurations: status, load and naming rules`

### Task 4: `AppModel` integration

**Files:**
- Create: `Wilco/Configurations/AppModel+Configurations.swift`
- Modify: `Wilco/AppModel.swift` (stored properties, launch migration in `init`)

**Interfaces:**
- Consumes: Tasks 1–3.
- Produces (on `AppModel`, all `@MainActor`):
  - stored: `let configurationStore: ConfigurationStore`, `private(set) var configurations: [ConfigurationSummary]`, `private(set) var loadedConfigurationID: UUID?` (persists to `configurations.loaded` in `didSet`), `private(set) var savedConfiguration: ShowDocument?`, `var configurationPendingLoad: UUID?` (drives the Save / Don't Save / Cancel dialog)
  - computed: `var configurationStatus: ConfigurationRules.Status`, `var windowTitle: String` (`document.name + titleSuffix`)
  - `func requestLoadConfiguration(_ id: UUID)`: applies `loadDecision`. Refuse sets `lastMessage = "Stop capture before loading a different configuration."`; ask sets `configurationPendingLoad`; alreadyLoaded does nothing; load calls `loadConfiguration`
  - `func loadConfiguration(_ id: UUID)`: reads the document; sets `document`, `savedConfiguration` and `loadedConfigurationID`; `clearTranscript()`; `clearActivity()`; clears `markers`; `selection = selection.validated(in: document)`; `saveNow()`. A read failure sets `lastMessage` and leaves everything unchanged.
  - `@discardableResult func saveConfiguration() -> Bool`: if `.notSaved`, returns `false` so the UI shows Save As New. Otherwise runs `saveNameCheck` (error → `lastMessage`, return `false`), writes, sets `savedConfiguration = document`, refreshes, returns `true`.
  - `func saveConfigurationAsNew(named: String)`: `create` with `document.name = uniqueName(named)`; sets the working name, saved snapshot and loaded ID
  - `func revertConfiguration()`: refused while capturing (same message wording with "reverting"); otherwise `document = savedConfiguration`. It does not clear the transcript.
  - `func newConfiguration()`, `func duplicateConfiguration(_:)`, `func renameConfiguration(_:to:)` (for the loaded one, also sets `document.name` and `savedConfiguration?.name` so the status stays unchanged), `func deleteConfiguration(_:)` (no-op for the loaded ID), `func importConfigurations(_ urls: [URL])` (failures → one `lastMessage` listing file names), `func exportConfiguration(_:to:)`, `func refreshConfigurations()`
  - Pending-load resolution: `func resolvePendingLoad(saveFirst: Bool)`. If `saveFirst` and the save fails, keep the pending load cleared and don't load.

- [ ] **Step 1: In `AppModel.init`**, after loading `Current.wilco`: call `configurationStore.migrateIfEmpty(from: document)`. If it returns an ID, set it as loaded with `savedConfiguration = document`. Otherwise read `configurations.loaded`; if `exists`, set `savedConfiguration = try? document(id)`, else `nil`. Then `refreshConfigurations()`.

- [ ] **Step 2: Implement** the extension. It writes nothing to disk except through `configurationStore` and the existing `saveNow()`.

- [ ] **Step 3: Build the app.** Expected: `** BUILD SUCCEEDED **`, no new warnings. Run the full `swift test`. Expected: all pass.

- [ ] **Step 4: Commit** `Configurations: load, save and revert in the app model`

### Task 5: Title menu, File menu and dialogs

**Files:**
- Create: `Wilco/Configurations/ConfigurationTitleMenu.swift` (menu content view), `Wilco/Configurations/ConfigurationCommands.swift` (`Commands`), `Wilco/Configurations/ConfigurationDialogs.swift` (a `ViewModifier` with the unsaved-changes dialog and the Save As New name sheet)
- Modify: `Wilco/MainWindowView.swift:31` (`.navigationTitle(model.windowTitle)`, `.toolbarTitleMenu { ConfigurationTitleMenu() }`, `.modifier(ConfigurationDialogs())`), `Wilco/WilcoApp.swift` (`.commands { ConfigurationCommands(...) }`)

**Interfaces:**
- Consumes: Task 4's `AppModel` API.
- Produces: `ConfigurationsWindow.windowID = "configurations"` (a constant; the view arrives in Task 6, and Manage Configurations… calls `openWindow(id:)` with it).

- [ ] **Step 1: Title menu contents**, in order:
  - one button per `model.configurations`, with a checkmark on the loaded one, calling `requestLoadConfiguration`, and `.disabled(model.isCapturing)`
  - Divider
  - `Save “‹name›”` ⌘S (disabled when `.saved`)
  - `Save As New…` ⇧⌘S
  - `Revert to Saved` (enabled only when `.edited` and not capturing)
  - Divider
  - `Manage Configurations…` ⇧⌘O

  Revert asks first: "Revert “‹name›” to its saved version? Your changes will be lost." with the buttons Revert / Cancel.

- [ ] **Step 2: File menu** via `CommandGroup(after: .newItem)`:
  - Save ⌘S, Save As New… ⇧⌘S, Revert to Saved
  - Divider
  - Configurations… ⇧⌘O, Import Configuration…, Export Configuration…

  Import and export use `NSOpenPanel` (`.allowedContentTypes` for the `wilco` extension, multiple selection) and `NSSavePanel` (default name `‹name›.wilco`). If ⌘S is already bound elsewhere, check with `grep -rn '"s", modifiers' Wilco`.

- [ ] **Step 3: Dialogs:**
  - Unsaved-changes `confirmationDialog`, bound to `configurationPendingLoad`: "Save changes to “‹current›” before loading “‹target›”?" with Save / Don't Save / Cancel, calling `resolvePendingLoad`
  - Save As New sheet: a name field prefilled `"‹name› copy"`, with Cancel / Save (disabled when blank)
  - When `saveConfiguration()` returns `false` because of `.notSaved`, open the Save As New sheet

- [ ] **Step 4: Build the app.** Expected: `** BUILD SUCCEEDED **`. If `.toolbarTitleMenu` doesn't show on the title next to the inspector toolbar, fall back to a `ToolbarItem(placement: .principal)` menu styled as the title. That choice is left to the builder by the spec.

- [ ] **Step 5: Commit** `Configurations: title menu, File menu and save dialogs`

### Task 6: Configurations window

**Files:**
- Create: `Wilco/Configurations/ConfigurationsWindow.swift`
- Modify: `Wilco/WilcoApp.swift` (add `Window("Configurations", id: ConfigurationsWindow.windowID)` with the `model` and `look` environments, like Show Report)

**Interfaces:**
- Consumes: Task 4's API and Task 5's `windowID` constant (move the constant here).

- [ ] **Step 1: Build the view:**
  - a `Table` of `model.configurations` with columns: checkmark/name, "Channels" (`channelCount`), "Saved" (`savedAt`, date and time, abbreviated)
  - single selection; double-click calls `requestLoadConfiguration`
  - a bottom bar with + (New), Duplicate, Rename (inline edit or a small sheet; errors from `ConfigurationError` show as `lastMessage`-style alerts with the text "A configuration needs a name." / "Another configuration is already called “X”."), Delete (disabled for the loaded one; confirmation "Delete “X”? This can't be undone."), Import…, Export…, and Load (default button, disabled when nothing is selected or while capturing)
  - window minimum size 520×320

- [ ] **Step 2: Call `refreshConfigurations()` in `.onAppear`** so files copied in by hand show up.

- [ ] **Step 3: Build the app.** Expected: `** BUILD SUCCEEDED **`, no new warnings.

- [ ] **Step 4: Commit** `Configurations: manager window`

### Task 7: Docs and hand-off for in-app testing

**Files:**
- Modify: `docs/SPEC.md` (in §3 files, add the `Configurations/` folder as new in the rebuild), `README.md` (add Configurations as "tested" in the status table), `docs/PROGRESS.md` (dated session section)

- [ ] **Step 1: Update the docs** in the existing plain style. PROGRESS lists the in-app checks for the user:
  - save two setups and switch between them
  - the patch, rules and OSC destinations all swap
  - the transcript clears
  - loading is refused while capturing
  - "— Edited" appears and clears
  - export, then import

- [ ] **Step 2: Run the full `swift test` and the app build** once more. Expected: all pass, `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit** `Configurations: docs`
