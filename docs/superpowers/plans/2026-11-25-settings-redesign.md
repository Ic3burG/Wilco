# Settings Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the 8-tab Settings window with one sidebar window split into "This Show" (five numbered setup steps with ticks) and "This Mac", with search, all model downloads in one place, and shorter on-page text.

**Architecture:** The page list, search index and tick rules are platform-free logic in `WilcoCore` (`Sources/WilcoCore/Settings/`), tested with Swift Testing. The app keeps the SwiftUI `Settings` scene and swaps its `TabView` for a `NavigationSplitView`; the selected page is one `@AppStorage` string that any page can write to jump elsewhere. Existing editors move over with their bindings unchanged.

**Tech Stack:** Swift 6 (strict concurrency), SwiftUI (macOS 15 target), Swift Testing.

**Spec:** `docs/superpowers/specs/2026-11-25-settings-redesign-design.md`

## Global Constraints

- Deployment target macOS 15; CI uses Xcode 26.6. No macOS 26/27-only API without `@available` guards.
- No change to `ShowDocument`, `.wilco`, `.jsonl`, model folders or existing preference keys. Only where controls appear changes.
- No new settings, no removed settings. The one addition is a download button (Apple long-form `en-US` for learning).
- Every control stays visible and one click away: no hover-only or overflow-menu controls.
- New preference key exactly `settings.selectedPage`; unknown or missing value → Audio.
- Show steps, in order: 1 Audio, 2 Speech, 3 Destinations, 4 Rules & Highlights, 5 Markers. Mac pages: General, Appearance, Speech Models, Learning.
- Don't name or version the reference app anywhere (code, comments, commits).
- Logic in the package gets tests; app-target changes are checked by the app build.
- Package tests: `cd Packages/WilcoCore && swift test`. App build: `xcodebuild build -project Wilco.xcodeproj -scheme Wilco -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY=""`.

## Review Focus

1. A search of only spaces or punctuation (for example `"  "` or `"›"`) returns no results and doesn't match everything. Tested in Task 1.
2. A hand-edited or out-of-date `settings.selectedPage` (for example `"languages"`, the old tab name) opens Audio rather than a blank page. Tested in Task 1.
3. A channel on an Apple engine with an empty `localeIdentifier` (meaning the Mac's language) is checked as that exact identifier, not skipped, so the Speech tick isn't falsely shown. Tested in Task 2. The app's check maps `""` to `Locale.current.identifier`, as Languages does today.
4. The show device is set but unplugged, or the show is on System Default with no channels: no Audio tick. Tested in Task 2.
5. A show imported with all its rules switched off by `OutboundRules` and no highlights has no Rules & Highlights tick. Destinations are unaffected. Tested in Task 2.

---

### Task 1: Page list and search index (WilcoCore)

**Files:**
- Create: `Packages/WilcoCore/Sources/WilcoCore/Settings/SettingsPage.swift`
- Create: `Packages/WilcoCore/Sources/WilcoCore/Settings/SettingsIndex.swift`
- Test: `Packages/WilcoCore/Tests/WilcoCoreTests/SettingsPageTests.swift`

**Interfaces:**
- Produces:
  - `public enum SettingsPage: String, CaseIterable, Sendable, Identifiable` with cases, in this order: `audio, speech, destinations, rules, markers, general, appearance, speechModels, learning`. Raw values are the case names.
  - `public enum SettingsPage.Area: Sendable { case show, mac }`, `var area: Area` (not `Group`, which would shadow SwiftUI's)
  - `var title: String`: "Audio", "Speech", "Destinations", "Rules & Highlights", "Markers", "General", "Appearance", "Speech Models", "Learning"
  - `var setupStep: Int?`: 1–5 for show pages in the order above, `nil` for Mac pages
  - `public static let storageKey = "settings.selectedPage"`
  - `public static func restored(from raw: String?) -> SettingsPage`: unknown or nil → `.audio`
  - `public struct SettingsIndex.Entry: Hashable, Sendable { title: String; keywords: [String]; page: SettingsPage }`
  - `public enum SettingsIndex { static let entries: [Entry]; static func search(_ query: String) -> [Entry] }`

- [ ] **Step 1: Write the failing tests** (`@Suite("Settings pages and search")`)

```swift
@Test func showStepsAreNumberedInSetupOrder() {
    #expect(SettingsPage.allCases.filter { $0.area == .show }.map(\.setupStep)
            == [1, 2, 3, 4, 5])
    #expect(SettingsPage.allCases.filter { $0.area == .mac }.allSatisfy { $0.setupStep == nil })
}
@Test func unknownStoredPageFallsBackToAudio() {
    #expect(SettingsPage.restored(from: nil) == .audio)
    #expect(SettingsPage.restored(from: "languages") == .audio)
    #expect(SettingsPage.restored(from: "speechModels") == .speechModels)
}
@Test func everyPageHasAnIndexEntry() {
    #expect(Set(SettingsIndex.entries.map(\.page)) == Set(SettingsPage.allCases))
}
@Test func searchMatchesWordPrefixesIgnoringCaseAndAccents() {
    #expect(SettingsIndex.search("voc").contains { $0.title == "Vocabulary" && $0.page == .speech })
    #expect(SettingsIndex.search("VOCAB").contains { $0.title == "Vocabulary" })
    #expect(SettingsIndex.search("voíce").contains { $0.page == .speech })
    #expect(SettingsIndex.search("osc").contains { $0.page == .destinations })
    #expect(SettingsIndex.search("text size").map(\.page) == [.appearance])
}
@Test func blankOrUnmatchedQueriesFindNothing() {
    #expect(SettingsIndex.search("").isEmpty)
    #expect(SettingsIndex.search("   ").isEmpty)
    #expect(SettingsIndex.search("›").isEmpty)
    #expect(SettingsIndex.search("zzqx").isEmpty)
}
```

- [ ] **Step 2: Run and confirm they fail.** Run `cd Packages/WilcoCore && swift test --filter SettingsPageTests`. Expected: build failure, `cannot find 'SettingsPage' in scope`.

- [ ] **Step 3: Implement `SettingsPage`.** One switch per property.

- [ ] **Step 4: Implement `SettingsIndex`.**
  - Write about 40 entries by hand, one for each visible control in the spec's "What moves where" table. Required entries: "Vocabulary" → `.speech`, "Text Size" → `.appearance`, and a Destinations entry with the keyword "osc".
  - Matching: fold the query and the entry's words with `.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)`, then split on non-alphanumerics. A query with no words returns `[]`. Each query word must be a prefix of some word in the entry's title or keywords. Results keep index order.

- [ ] **Step 5: Run and confirm they pass.** Same command. Expected: all 5 pass.

- [ ] **Step 6: Commit.** `git add` the three files, then commit: "Settings: page list and search index".

---

### Task 2: Setup ticks (WilcoCore)

**Files:**
- Create: `Packages/WilcoCore/Sources/WilcoCore/Settings/ShowSetupProgress.swift`
- Test: `Packages/WilcoCore/Tests/WilcoCoreTests/ShowSetupProgressTests.swift`

**Interfaces:**
- Consumes: `SettingsPage` (Task 1); `ShowDocument`, `ChannelConfig`, `OSCDestination`, `AutomationRule`, `HighlightRule`, `OutboundRules.turningOff(in:)` (existing).
- Produces: `public enum ShowSetupProgress { public static func isSetUp(_ page: SettingsPage, show: ShowDocument, connectedDeviceUIDs: Set<String>, isInstalled: (SpeechEngine, String) -> Bool) -> Bool }`

Rules (from the spec):
- `.audio`: at least one channel, and `deviceUID` is either `nil` or in `connectedDeviceUIDs`.
- `.speech`: at least one channel, and `isInstalled(engine, localeIdentifier)` is true for every distinct (engine, localeIdentifier) pair.
- `.destinations`: some destination has `isEnabled`.
- `.rules`: some rule or highlight has `isEnabled`.
- Anything else (`.markers` and the Mac pages): `false`.

- [ ] **Step 1: Write the failing tests.**
  - Use `@Suite("Show setup ticks")`.
  - Build shows the way `OutboundRulesTests` does, with `ShowDocument(name:)` and then setting fields. Each test asserts both the ticked and the unticked case:
    - `audioNeedsAChannelAndAConnectedDevice`:
      - no channels with `deviceUID == nil` → false
      - one channel with `nil` → true
      - one channel with `"X"` when connected is `[]` → false
      - the same with connected `["X"]` → true
    - `speechNeedsEveryChannelModelInstalled`:
      - two channels `(.parakeet, "en-US")` and `(.longForm, "")`, where the predicate returns true only for parakeet → false
      - the same with a predicate that is true for both → true
      - record the pairs the predicate receives and `#expect` that they include `(.longForm, "")`
      - no channels → false
    - `destinationsNeedOneEnabled`: one disabled → false; one enabled → true
    - `rulesOrHighlightsCount`:
      - none → false
      - only an enabled highlight → true
      - an import whose only rule is a webhook, run through `OutboundRules.turningOff(in:)`, with no highlights → false
      - in that same imported show, an enabled destination still ticks `.destinations`
    - `markersAndMacPagesNeverTick`: every page in `[.markers, .general, .appearance, .speechModels, .learning]` → false, even for a fully set-up show

- [ ] **Step 2: Run and confirm they fail.** Run `swift test --filter ShowSetupProgressTests`. Expected: `cannot find 'ShowSetupProgress'`.

- [ ] **Step 3: Implement `ShowSetupProgress.isSetUp`.**

- [ ] **Step 4: Run and confirm they pass.** Then run the full `swift test`. Expected: all green, including `SecurityGuardrailTests`.

- [ ] **Step 5: Commit.** Message: "Settings: setup ticks for show pages".

---

### Task 3: Split Languages into Speech and Speech Models; slim Learning

The app still uses the `TabView` after this task: Languages is replaced by two tabs, Speech and Speech Models, so the app builds and runs between tasks.

**Files:**
- Create: `Wilco/Settings/SpeechSettingsView.swift`. It moves these out of `LanguagesSettingsView`:
  - global vocabulary
  - New Channels section
  - Whisper model **picker** (the `document.whisperModel` binding)
  - Voice Changes tuning: threshold, exchange gap, Restore Defaults
- Create: `Wilco/Settings/SpeechModelsSettingsView.swift`, with two sections:
  - *For this show's channels*: Whisper download and other Whisper sizes on disk, the Parakeet and vocabulary rows, the voice model row, and the per-language Apple rows with `refresh()`
  - *For learning*: Parakeet Ultra, Whisper large-v3, voice grouping (moved from `LearningSettingsView.votersSection`), and **Apple Long-form (English, US)**, which shows its status plus an **Install** button calling `installer.install(.apple(.longForm, localeIdentifier: "en-US"))` when not installed
- Delete: `Wilco/Settings/LanguagesSettingsView.swift` once it is empty. Move shared helpers (`status(for:)`, `folderSize`) into `SpeechModelsSettingsView`.
- Modify: `Wilco/Settings/LearningSettingsView.swift`:
  - Replace the voters section with a read-only "Voters" section: `LabeledContent("Installed", value: "\(n) of 4")`, counting Parakeet Ultra, Apple long-form `en-US`, Whisper large-v3 and voice grouping.
  - Add a visible button **Speech Models…** that sets `@AppStorage(SettingsPage.storageKey)` to `SettingsPage.speechModels.rawValue`.
  - Keep the footer "Labelling needs at least two…".
- Modify: `Wilco/Settings/SettingsView.swift`, swapping the Languages tab for the Speech and Speech Models tabs.

**Interfaces:**
- Consumes: `SettingsPage.storageKey`, `.speechModels` (Task 1); `ModelInstaller` (existing).
- Produces: `struct SpeechSettingsView: View` and `struct SpeechModelsSettingsView: View`, both taking `AppModel` from the environment with no initializer arguments.

- [ ] **Step 1: Make the moves.** Keep every binding and behaviour, including the 3-second refresh loop on Speech Models. The voice-change *model download* row goes to Speech Models; the tuning stays on Speech.
- [ ] **Step 2: Build the app.** Run the app build command. Expected: `** BUILD SUCCEEDED **` with no new warnings.
- [ ] **Step 3: Run the full `swift test`.** Expected: all pass. If a guardrail fails, read its message and do what it names.
- [ ] **Step 4: Commit.** Message: "Settings: split Languages into Speech and Speech Models".

---

### Task 4: Sidebar window with ticks and search

**Files:**
- Create: `Wilco/Settings/SettingsSidebar.swift`, containing the sidebar list, the search results list and the tick badge.
- Create: `Wilco/Settings/SetupStatus.swift`, an `@MainActor @Observable final class SetupStatus`:
  - Holds `installedPairs: Set<InstalledPair>` (engine + locale).
  - Refreshes every 3 s while Settings is open, using the same checks as `SpeechModelsSettingsView.refresh()`: Whisper selected model size on disk, `parakeetStore.isInstalled()`, and `SpeechAssets.status(...) == .installed` for Apple engines, with `""` mapped to `Locale.current.identifier`.
  - Provides `func isInstalled(_ engine: SpeechEngine, _ locale: String) -> Bool`.
- Modify: `Wilco/Settings/SettingsView.swift`, replacing the `TabView`:
  - Use `NavigationSplitView`. The sidebar has a "This Show" section and a "This Mac" section built from `SettingsPage.allCases` by `area`.
  - Selection comes from `@AppStorage(SettingsPage.storageKey) private var storedPage = SettingsPage.audio.rawValue`, read through `SettingsPage.restored(from:)`.
  - The detail view switches on the page: `AudioSettingsView`, `SpeechSettingsView`, `DestinationSettingsView`, `AutomationSettingsView`, `MarkerSettingsView`, `GeneralSettingsView`, `LookAndFeelSettingsView`, `SpeechModelsSettingsView`, `LearningSettingsView`.
  - Remove the fixed `SettingsView.size` and `settingsPane()`. Give the split view `.frame(minWidth: 900, minHeight: 600)`.
- Modify: `Wilco/WilcoApp.swift:47`. Add `.windowResizability(.contentMinSize)` to the `Settings` scene.

**Interfaces:**
- Consumes: `SettingsPage`, `SettingsIndex.search` (Task 1); `ShowSetupProgress.isSetUp` (Task 2); `SpeechSettingsView`, `SpeechModelsSettingsView` (Task 3); `model.devices.map(\.id)` for connected UIDs.

Sidebar details:
- Show rows: a number badge (`setupStep`) and the title, with a trailing `checkmark` in green when `isSetUp`. The accessibility label is "\(title), set up" or just "\(title)".
- Mac rows: `Label(title, systemImage:)`, using `gearshape`, `textformat.size`, `arrow.down.circle` and `graduationcap`.
- Add `.searchable(text:placement: .sidebar)`. While the query isn't blank, show `SettingsIndex.search(query)` rows as "Title — Page title". Choosing one sets the stored page and clears the query. With no results, show `ContentUnavailableView.search(text:)`.

- [ ] **Step 1: Build `SetupStatus`, `SettingsSidebar` and the new `SettingsView` as above.**
- [ ] **Step 2: Build the app.** Expected: `** BUILD SUCCEEDED **`.
- [ ] **Step 3: Check resizing.** Launch the built app, open Settings (⌘,) and drag the window corner. If it won't resize on this macOS, drop `.windowResizability` and use a fixed `.frame(width: 1060, height: 640)`. Don't use AppKit window code. Note which way it went in the commit message.
- [ ] **Step 4: Run the full `swift test`.** Expected: all pass.
- [ ] **Step 5: Commit.** Message: "Settings: sidebar with This Show / This Mac, ticks and search".

---

### Task 5: Visual refresh: page headers, one-line captions, ⓘ

**Files:**
- Create: `Wilco/Components/InfoButton.swift`, with `struct InfoButton: View { let text: String }`:
  - a borderless `Image(systemName: "info.circle")` button that shows a popover with `text` at a width of about 320 pt
  - `.help("More about this")`
  - accessibility label "More information"
- Create: `Wilco/Settings/SettingsPageHeader.swift`, with `struct SettingsPageHeader: View { let page: SettingsPage; let summary: String }`. It shows the title in `.title2.bold()` and the summary in `.secondary`, placed above each page's `Form`. It is added once in `SettingsView`'s detail view, with one summary per page held in a `switch` there.
- Modify: every page view in `Wilco/Settings/` plus the Audio and General views in `SettingsView.swift`. Any footer longer than one sentence keeps its first sentence and moves the rest into `InfoButton(text:)` inside the same footer `HStack`. Don't change the wording.

Page summaries (exact copy):
- Audio: "Where this show's sound comes from."
- Speech: "How this show's channels are transcribed."
- Destinations: "Consoles and machines rules can send to."
- Rules & Highlights: "What happens when a phrase is heard."
- Markers: "Run-of-show moments the report picks out."
- General: "How Wilco behaves on this Mac."
- Appearance: "How the transcript looks on this Mac."
- Speech Models: "Downloads shared by every show on this Mac."
- Learning: "Clips Wilco keeps to learn from your shows."

- [ ] **Step 1: Add the two components and the headers.**
- [ ] **Step 2: Trim the footers page by page.** Each footer should be no more than one sentence plus an ⓘ.
- [ ] **Step 3: Build the app.** Expected: `** BUILD SUCCEEDED **`.
- [ ] **Step 4: Commit.** Message: "Settings: page headers, one-line captions with info popovers".

---

### Task 6: Text that names old tabs, and the docs

**Files:**
- Modify: these in-app messages, which change wording only:
  - `Wilco/AppModel.swift:369`: "Settings › Automation" → "Settings › Rules & Highlights"
  - `Wilco/Configurations/AppModel+Configurations.swift:237`: the same change
  - `Packages/WilcoCore/Sources/WilcoCore/Report/Review/ShowReview.swift:492`: the same change
  - `Packages/WilcoCore/Sources/WilcoBench/BenchEngine.swift:93`: "Settings › Languages" → "Settings › Speech Models"
  - `Wilco/Settings/AutomationSettingsView.swift:218`: already says Destinations; check it still reads correctly
- Modify: these places in `docs/SPEC.md`:
  - the **Settings** paragraph (around line 604): replace it with the new page list and `settings.selectedPage`
  - "Settings › Learning" mentions that now refer to downloads → "Settings › Speech Models"
  - "Settings › Languages › New Channels" → "Settings › Speech › New Channels"
  - "Settings › Automation" → "Settings › Rules & Highlights"
- Modify: any tests that assert on the changed strings. Find them with `grep -rn "Settings ›" Packages/WilcoCore/Tests`.

- [ ] **Step 1: Find any remaining references.** Run `grep -rn "Settings ›\|in Languages\|(Languages)" Wilco Packages docs/SPEC.md README.md`. Expected: only the hits listed above, plus the System Settings microphone message, which stays as it is.
- [ ] **Step 2: Make the edits.**
- [ ] **Step 3: Run the full `swift test` and the app build.** Expected: both pass.
- [ ] **Step 4: Commit.** Message: "Settings: point messages and spec at the new page names".

---

### Task 7: Security check and progress log

- [ ] **Step 1: Check the change against §5 of the security model by hand.** `/security-review` doesn't work in worktrees here. Confirm the spec's answers still hold, especially that search only shows `SettingsIndex` text and never text from the show.
- [ ] **Step 2: Add a dated section to `docs/PROGRESS.md`.** Mark the new Settings as "tested", not "verified", until the owner tries it. Next steps: owner to try it on a real show.
- [ ] **Step 3: Commit.** Message: "Progress: Settings redesign".
