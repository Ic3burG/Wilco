# Editable Report Markers Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let each show carry its own run-of-show marker lists, editable from a new Markers tab in Settings, with unedited shows behaving exactly as today.

**Architecture:** A `MarkerSettings` value in WilcoCore holds phrase labels, a department list and two built-in switches. `ShowDocument.markers` is optional (`nil` = built-in `.standard`). `MarkerDetector` is driven by those settings instead of a hard-coded rule table. The app gets a thin Settings tab that edits `model.document.markers`.

**Tech Stack:** Swift 6 (strict concurrency), SwiftUI (macOS 15 deployment target), Swift Testing.

**Spec:** `docs/superpowers/specs/2026-11-21-editable-report-markers-design.md`

## Global Constraints

- Existing `.wilco` shows must keep opening. New fields need defaults; an unedited show must encode without a `markers` key.
- `report-v1.html`, `report-v1.srt` and `report-v1.vtt` fixtures stay identical (`ReportVoiceTests`).
- The five categories stay fixed: `phase, houseLights, song, cue, department`.
- No regular expressions in the UI.
- Don't name the reference app anywhere (code, comments, docs, commits).
- CI runs Xcode 26.6: no macOS 27-only SwiftUI API without an availability guard.
- Swift 6 language mode; fix warnings, don't silence them.
- Package tests: `cd Packages/WilcoCore && swift test`. App build: `xcodebuild build -project Wilco.xcodeproj -scheme Wilco -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY=""`.

## Review Focus

1. **A show saved by a newer build with a category this build doesn't know.** The show opens; that label is dropped. Test in Task 1.
2. **Phrases typed with capitals, punctuation or extra spaces** (`"  House To Half! "`). These match like automation phrases do, via `KeywordMatcher` tokens. Test in Task 2.
3. **Multi-word departments** (`"follow spot"`) match "follow spot go" and "go follow spot". Test in Task 2.
4. **Blank phrases or departments, or a category with every label deleted.** Nothing matches and nothing crashes. Test in Task 2.
5. **Real sessions on this Mac come out the same as with the old regex rules,** apart from the intended widening ("go band" style). This is a temporary local-only comparison in Task 2.

---

### Task 1: `MarkerSettings` model and storage in the show

**Files:**
- Create: `Packages/WilcoCore/Sources/WilcoCore/Model/MarkerSettings.swift`
- Modify: `Packages/WilcoCore/Sources/WilcoCore/Report/ShowReport.swift:5` (make `MarkerCategory` `Codable`)
- Modify: `Packages/WilcoCore/Sources/WilcoCore/Model/ShowDocument.swift` (property, `CodingKeys`, `init(from:)`)
- Test: `Packages/WilcoCore/Tests/WilcoCoreTests/MarkerSettingsTests.swift`

**Interfaces:**
- Produces:
  - `public struct MarkerLabel: Codable, Equatable, Identifiable, Sendable { id: UUID; category: ShowReport.MarkerCategory; name: String; isEnabled: Bool; phrases: [String] }` with `init(id: UUID = UUID(), category:, name:, isEnabled: Bool = true, phrases: [String] = [])`.
  - `public struct MarkerSettings: Codable, Equatable, Sendable { labels: [MarkerLabel]; departments: [String]; departmentGosEnabled: Bool; countdownEnabled: Bool; songStartEnabled: Bool; static let standard: MarkerSettings }`.
  - `public func labels(in category: ShowReport.MarkerCategory) -> [MarkerLabel]` (list order).
  - `ShowDocument.markers: MarkerSettings? = nil` and `public var markerSettings: MarkerSettings { markers ?? .standard }`.

- [ ] **Step 1: Write the failing tests** (`@Suite("Marker settings")`)

```swift
@Test func showWithoutMarkersDecodesNil() throws {
    let show = try WilcoJSON.decoder().decode(ShowDocument.self, from: fixture("show-v1.wilco"))
    #expect(show.markers == nil)
    #expect(show.markerSettings == .standard)
}
@Test func uneditedShowEncodesWithoutMarkersKey() throws {
    let json = String(decoding: try WilcoJSON.encoder().encode(ShowDocument()), as: UTF8.self)
    #expect(!json.contains("\"markers\""))
}
@Test func editedMarkersRoundTrip() throws {
    var show = ShowDocument()
    var settings = MarkerSettings.standard
    settings.labels.append(MarkerLabel(category: .phase, name: "Keynote", phrases: ["keynote"]))
    settings.departments.append("rigging")
    settings.countdownEnabled = false
    show.markers = settings
    let decoded = try WilcoJSON.decoder().decode(ShowDocument.self, from: WilcoJSON.encoder().encode(show))
    #expect(decoded == show)
}
@Test func partialMarkerSettingsFillDefaults() throws {
    let data = Data(#"{"departments":["rigging"]}"#.utf8)
    let settings = try WilcoJSON.decoder().decode(MarkerSettings.self, from: data)
    #expect(settings.departments == ["rigging"])
    #expect(settings.labels == [])          // labels present-but-missing means none, not defaults
    #expect(settings.departmentGosEnabled && settings.countdownEnabled && settings.songStartEnabled)
}
@Test func labelWithUnknownCategoryIsSkipped() throws {
    let data = Data(#"{"labels":[{"id":"\#(UUID())","category":"pyroCues","name":"X","isEnabled":true,"phrases":["x"]},{"id":"\#(UUID())","category":"cue","name":"Hold","isEnabled":true,"phrases":["hold"]}]}"#.utf8)
    let settings = try WilcoJSON.decoder().decode(MarkerSettings.self, from: data)
    #expect(settings.labels.map(\.name) == ["Hold"])
}
@Test func standardMatchesTodaysLists() {
    let standard = MarkerSettings.standard
    #expect(standard.labels(in: .phase).map(\.name) == ["Doors", "Walk-in", "Top of show", "Downbeat", "Blackout", "Curtain", "Intermission", "Encore", "Show clear", "Load out"])
    #expect(standard.labels(in: .houseLights).map(\.name) == ["House lights out", "House lights at half", "House lights up", "House lights discussed"])
    #expect(standard.labels(in: .song).map(\.name) == ["Playback"])
    #expect(standard.labels(in: .cue).map(\.name) == ["Standby", "Hold"])
    #expect(standard.labels(in: .department).isEmpty)
}
```

Use the same `fixture(_:)` helper as `FileFormatTests`.

- [ ] **Step 2: Run to verify failure**

Run: `cd Packages/WilcoCore && swift test --filter "Marker settings"`
Expected: compile failure, `MarkerSettings` not found.

- [ ] **Step 3: Implement**

`MarkerSettings.swift`:
- Copy the phrase lists for `.standard` verbatim from the `rules` array in `MarkerDetector.swift`, in the same order.
- `departments` defaults: `["LX", "lighting", "sound", "audio", "video", "content", "pyro", "laser", "lasers", "spot", "spots", "fly", "deck", "band", "screen", "screens", "graphics", "confetti"]`. "LX" is typed uppercase so its label reads "LX go".
- Custom `init(from:)` with `decodeIfPresent` for every key. A missing `labels` key decodes to `[]`; missing Bools decode to `true`; missing `departments` decodes to `[]`.
- Decode `labels` lossily: decode an array of a private wrapper whose `init(from:)` uses `try?` and yields `nil` for an unknown category, then `compactMap`.

`ShowDocument`: add `markers` to `CodingKeys`, then `markers = try c.decodeIfPresent(MarkerSettings.self, forKey: .markers)`. The synthesised `encode(to:)` already omits a `nil` optional.

- [ ] **Step 4: Run to verify pass**

Run: `cd Packages/WilcoCore && swift test`
Expected: all pass, including the existing `FileFormatTests`.

- [ ] **Step 5: Commit**

```bash
git add Packages/WilcoCore/Sources/WilcoCore/Model/MarkerSettings.swift Packages/WilcoCore/Sources/WilcoCore/Model/ShowDocument.swift Packages/WilcoCore/Sources/WilcoCore/Report/ShowReport.swift Packages/WilcoCore/Tests/WilcoCoreTests/MarkerSettingsTests.swift
git commit -m "Shows can carry their own report marker lists"
```

---

### Task 2: Detector driven by `MarkerSettings`

**Files:**
- Modify: `Packages/WilcoCore/Sources/WilcoCore/Report/MarkerDetector.swift`
- Modify: `Packages/WilcoCore/Sources/WilcoCore/Report/ShowReport.swift:179`
- Test: `Packages/WilcoCore/Tests/WilcoCoreTests/ShowReportTests.swift` (`MarkerDetectorTests`)

**Interfaces:**
- Consumes: `MarkerSettings`, `MarkerLabel`, `ShowDocument.markerSettings` (Task 1).
- Produces: `public static func detect(in text: String, settings: MarkerSettings = .standard) -> [Detection]`. `Detection` is unchanged.

- [ ] **Step 1: Add a temporary local comparison (Review Focus 5)**

Before changing the detector, copy the current `MarkerDetector` to `Tests/WilcoCoreTests/LegacyMarkerDetector.swift` and rename it `LegacyMarkerDetector`. Add a test gated like `everySessionOnThisMacBuildsAReport`. It runs every final line of every session in `DataLocations.transcripts` through both detectors, records each line where `"category:label"` lists differ, and `#expect`s that the only differences are department labels that the new rules add (for example "Go band") or that differ only in letter case ("Lx go" becoming "LX go"). Run it after Step 4, report the differences to the user, then delete both the copy and the test before committing.

- [ ] **Step 2: Write the failing tests**

```swift
private func labels(_ text: String, _ settings: MarkerSettings) -> [String] {
    MarkerDetector.detect(in: text, settings: settings).map { "\($0.category.rawValue):\($0.label)" }
}
@Test func customLabelIsDetected() {
    var s = MarkerSettings.standard
    s.labels.append(MarkerLabel(category: .phase, name: "Keynote", phrases: ["  Key Note! "]))
    #expect(labels("Standby for the key note", s) == ["phase:Keynote", "cue:Standby"])
}
@Test func disabledLabelIsSkipped() {
    var s = MarkerSettings.standard
    s.labels = s.labels.map { var l = $0; if l.name == "Standby" { l.isEnabled = false }; return l }
    #expect(labels("Stand by pyro", s) == [])
}
@Test func earlierLabelWinsWithinACategory() {
    var s = MarkerSettings.standard
    s.labels.insert(MarkerLabel(category: .houseLights, name: "Houses", phrases: ["house lights"]), at: 0)
    #expect(labels("House lights out", s) == ["houseLights:Houses"])
}
@Test func addedDepartmentMatchesEitherOrder() {
    var s = MarkerSettings.standard
    s.departments += ["rigging", "follow spot"]
    #expect(labels("Rigging go", s) == ["department:Rigging go"])
    #expect(labels("go follow spot", s) == ["department:Go follow spot"])
    #expect(labels("Follow spot, go", s) == ["department:Follow spot go"])
}
@Test func cueNumberGoIsAlwaysMatched() {
    var s = MarkerSettings.standard
    s.departments = []
    #expect(labels("Cue 47 go", s) == ["department:Cue 47 go"])
}
@Test func departmentGosCanBeTurnedOff() {
    var s = MarkerSettings.standard
    s.departmentGosEnabled = false
    #expect(labels("Pyro go", s) == [])
}
@Test func builtInPatternsCanBeTurnedOff() {
    var s = MarkerSettings.standard
    s.countdownEnabled = false; s.songStartEnabled = false
    #expect(labels("We're 5 minutes to doors", s) == [])
    #expect(labels("Going into the next song", s) == [])
}
@Test func blanksAndEmptyCategoriesMatchNothing() {
    var s = MarkerSettings.standard
    s.labels = [MarkerLabel(category: .cue, name: "Empty", phrases: ["", "   "])]
    s.departments = ["", " "]
    #expect(labels("Standby, go", s) == [])
}
@Test func reportUsesTheShowsMarkers() { /* build a ShowReport with show.markers containing a "Keynote" phase label; expect a marker labelled "Keynote" */ }
```

The existing `recognisesEachCategory`, `oneLineCanMarkSeveralCategories`, `mentioningHouseLightsIsTheLeastSpecificMatch` and `ordinaryChatterMarksNothing` stay unchanged and use the default `settings`.

- [ ] **Step 3: Run to verify failure**

Run: `cd Packages/WilcoCore && swift test --filter MarkerDetector`
Expected: compile failure, there's no `settings:` parameter yet.

- [ ] **Step 4: Implement**

Replace the static `rules` table. Keep two private compiled regexes: the countdown regex and the song-start regex, copied verbatim. Per category, in `ShowReport.MarkerCategory.allCases` order, the first match wins:

- `.phase`: enabled labels in order, then countdown if `countdownEnabled` (label `"Countdown"`).
- `.houseLights`, `.cue`: enabled labels in order.
- `.song`: song start if `songStartEnabled` (label `"Song start"`), then enabled labels.
- `.department`, if `departmentGosEnabled`:
  - For each non-blank department, take `d = KeywordMatcher.tokens(department)` and look for the token run `d + ["go"]` or `["go"] + d` in the line's words. Label and matched text: `"<Department> go"` or `"Go <department>"`, using the department as typed with its first letter uppercased.
  - Then the cue-number rule: the tokens `cue, <digits>, go` or `go, cue, <digits>`, labelled `"Cue N go"` / `"Go cue N"`.

  Use exact consecutive-token matching. Don't use `KeywordMatcher.firstMatch` here, because it joins words ("pyrogo").
- Phrase labels use `KeywordMatcher.firstMatch(of:in:)`, with each label's phrases split into words for each `detect` call. `matched` is the phrase that matched, as typed.

`ShowReportBuilder.build`: call `MarkerDetector.detect(in: line.text, settings: show.markerSettings)`. Read `show.markerSettings` once, outside the loop.

- [ ] **Step 5: Run to verify pass**

Run: `cd Packages/WilcoCore && swift test`
Expected: all pass, including `ReportVoiceTests` against the `report-v1.*` fixtures, and the local comparison from Step 1 on this Mac. Show the user the comparison's differences, then delete `LegacyMarkerDetector.swift` and its test.

- [ ] **Step 6: Commit**

```bash
git add Packages/WilcoCore/Sources/WilcoCore/Report Packages/WilcoCore/Tests/WilcoCoreTests/ShowReportTests.swift
git commit -m "Report markers come from the show's lists; departments replace the go pattern"
```

---

### Task 3: Markers tab in Settings

**Files:**
- Create: `Wilco/Settings/MarkerSettingsView.swift`
- Modify: `Wilco/Settings/SettingsView.swift` (add the tab after Automation)

**Interfaces:**
- Consumes: `model.document.markers`, `model.document.markerSettings`, `MarkerLabel`, `MarkerSettings.labels(in:)`, `ShowReport.MarkerCategory.title` (Tasks 1–2). Reuses `TokenListEditor(tokens:prompt:)` from `Wilco/Components/TokenListEditor.swift`.

- [ ] **Step 1: Add the tab.** Use `Tab("Markers", systemImage: "flag") { MarkerSettingsView() }`.

- [ ] **Step 2: Build `MarkerSettingsView`** with the same skeleton as `AutomationSettingsView`: a bordered `List` 230 wide, an editor beside it, and the whole view at `.frame(width: 860, height: 600)`.

  - **Editing.** Edits go through one binding: `get: model.document.markerSettings`, `set: model.document.markers = $0`. The first edit stores the full set. Don't store `nil` when the result happens to equal `.standard`.
  - **Selection.** A private enum: `.label(MarkerLabel.ID) | .countdown | .songStart | .departments`.
  - **List.** One `Section` per category (`category.title`) listing `labels(in:)`. Show phases ends with a "Countdown" row and Songs with a "Song start" row; give both a `"wand.and.stars"` icon to mark them as built in. Department gos has a single "Departments" row. A disabled label uses a dimmed icon, as `bolt.slash` does for rules.
  - **Reordering.** `.onMove` inside each category section moves labels within that category only. Reorder in the flat `labels` array by mapping section offsets to array indexes.
  - **Bottom bar.** Laid out like Automation's.
    - A `+` `Menu` with "New Label in \(category.title)" for phase, houseLights, song and cue. Each item appends `MarkerLabel(category:, name: "New Label")` and selects it.
    - A `–` button that deletes the selected label. It's disabled for built-in rows and Departments.
    - "Restore Defaults…" opens a `confirmationDialog` ("Restore the built-in markers?" / "This show's marker lists are replaced with Wilco's built-in ones."), then sets `model.document.markers = nil` and clears the selection.
  - **Editors.** These go in a `Form` with `.formStyle(.grouped)`, like `RuleEditor`.
    - A label gets a Name `TextField`, an "Enabled" `Toggle` and `TokenListEditor(tokens: $label.phrases, prompt: "Add a phrase, e.g. house to half")`. Footer: "Whole words, any letter case. Labels are checked top to bottom; the first match in a category wins."
    - Countdown gets a Toggle. Footer: "Marks calls like “5 minutes to doors” or “we're at 10 minutes”."
    - Song start gets a Toggle. Footer: "Marks calls like “top of the next song” or “playback rolling”."
    - Departments gets a Toggle and `TokenListEditor(tokens: $settings.departments, prompt: "Add a department, e.g. rigging")`. Footer: "Matches “rigging go” and “go rigging”. “Cue 12 go” is always matched."
  - **List footer.** "Reports use the markers saved with the show a session was recorded with."

- [ ] **Step 3: Build the app**

Run the app build command from Global Constraints.
Expected: `** BUILD SUCCEEDED **` with no new warnings.

- [ ] **Step 4: Commit**

```bash
git add Wilco/Settings/MarkerSettingsView.swift Wilco/Settings/SettingsView.swift
git commit -m "Markers tab in Settings to tune report markers per show"
```

---

### Task 4: Docs

**Files:**
- Modify: `docs/SPEC.md` §8

- [ ] **Step 1: Rewrite the first paragraph of §8.**
  - Marker rules are per show (`ShowDocument.markers`, `nil` = built-in).
  - They're edited in Settings › Markers.
  - Departments are a name list, matched as "X go" or "go X", plus "cue N go".
  - Countdown and song start are built-in switches.
  - A report uses the recorded-with show's markers.

  Keep the existing list of built-in phase labels.

- [ ] **Step 2: Run the full package tests.** `cd Packages/WilcoCore && swift test`. Expected: pass.

- [ ] **Step 3: Commit**

```bash
git add docs/SPEC.md docs/superpowers
git commit -m "Spec: editable report markers"
```

The PROGRESS.md entry and push happen at session end, per CLAUDE.md. Report the feature as "tested", not "verified", until the user tries the tab in the app.
