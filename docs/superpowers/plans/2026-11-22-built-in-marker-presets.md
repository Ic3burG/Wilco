# Built-in Marker Presets and Talkback Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Talkback marker category, a "<department> <number> go" match, and read-only built-in Concert, Corporate and Theatre presets in the Presets menu.

**Architecture:** `MarkerCategory.talkback` is matched like the other phrase categories. `MarkerPreset.builtIn` builds the three presets in code from `.standard` plus changes, with fixed UUIDs. `MarkerPresetsMenu` lists them under a "Built-in" heading.

**Tech Stack:** Swift 6, SwiftUI, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-11-22-built-in-marker-presets-design.md`. The user approved it, including the phrase lists and the "LX 47 go" match.

## Global Constraints

- `.standard` is unchanged and gets no talkback labels. The `report-v1.*` fixtures must stay identical.
- `talkback` is the last case of `MarkerCategory`, titled "Talkback" and tinted `.purple`.
- Built-ins are never written to the presets folder and don't appear in Manage Presets.
- The usual rules: don't name the reference app, guard for CI Xcode 26.6, no new warnings. Package tests: `cd Packages/WilcoCore && swift test`. Run the app build command from CLAUDE.md.

## Review Focus

1. **The number form vs. today's matches.** "LX 47 go" is new. "cue 47 go" must keep its label "Cue 47 go", and "LX go" must still match. Test in Task 1.
2. **A number between "go" and a department** ("go LX 47") gets the same treatment as "LX 47 go". Test in Task 1.
3. **A user preset with the same name as a built-in.** Both are listed, the user's under its own heading, and loading either loads the right one. The IDs differ by construction. Checked by hand in the app.
4. **Built-in phrase lists with duplicate phrases, or phrases already in `.standard`.** Matching isn't affected, but the editor's `ForEach(id: \.self)` would break. Test in Task 2.
5. **An older build opening a show that loaded the Concert preset.** The talkback labels are dropped and the show still opens. Already covered by `labelWithUnknownCategoryIsSkipped`.

---

### Task 1: Talkback category and "<department> <number> go"

**Files:**
- Modify: `Packages/WilcoCore/Sources/WilcoCore/Report/ShowReport.swift` (enum, `title`, `tint`)
- Modify: `Packages/WilcoCore/Sources/WilcoCore/Report/MarkerDetector.swift` (`.talkback` goes through `phrase`; add department plus number runs)
- Modify: `Wilco/Settings/MarkerSettingsView.swift` (add `.talkback` to `labelCategories`; `builtInRows` returns `EmptyView` for it)
- Test: `Packages/WilcoCore/Tests/WilcoCoreTests/ShowReportTests.swift`

**Interfaces:** Produces `ShowReport.MarkerCategory.talkback`.

- [ ] **Step 1: Write the failing tests** in `MarkerDetectorTests`:

```swift
@Test func talkbackLabelsAreDetected() {
    var s = MarkerSettings.standard
    s.labels.append(MarkerLabel(category: .talkback, name: "Monitor request", phrases: ["more me"]))
    #expect(labels("Can I get more me please", s) == ["talkback:Monitor request"])
}
@Test func standardHasNoTalkbackLabels() { #expect(MarkerSettings.standard.labels(in: .talkback).isEmpty) }
@Test func departmentWithACueNumber() {
    #expect(labels("LX 47 go") == ["department:LX 47 go"])
    #expect(labels("go sound 12") == ["department:Go sound 12"])
    #expect(labels("Cue 47 go") == ["department:Cue 47 go"])
    #expect(labels("LX go") == ["department:LX go"])
    #expect(labels("pyro 3") == [])
}
```

- [ ] **Step 2: Run** `swift test --filter MarkerDetectorTests`. Expected: a compile failure, because `.talkback` doesn't exist yet.
- [ ] **Step 3: Implement.**
  - Each department run gains a number variant, matched at detect time: the department's words, a token of digits, then "go" (label `"<Name> <n> go"`), or "go", the department's words and digits (label `"Go <name> <n>"`).
  - They take part in the same rule: the call said first wins, then the longest.
  - The longer run means "LX 47 go" beats nothing and "lx go" is unaffected.
- [ ] **Step 4: Run all package tests and the app build.** Expected: all pass, fixtures included.
- [ ] **Step 5: Commit** with "Markers: Talkback category; '<department> <number> go'".

### Task 2: Built-in presets

**Files:**
- Create: `Packages/WilcoCore/Sources/WilcoCore/Model/MarkerSettings+BuiltIn.swift`
- Test: `Packages/WilcoCore/Tests/WilcoCoreTests/MarkerPresetStoreTests.swift` (new suite `BuiltInPresetTests`)

**Interfaces:** Produces `public extension MarkerPreset { static let builtIn: [MarkerPreset] }`, in the order Concert, Corporate, Theatre. IDs are fixed UUID literals.

- [ ] **Step 1: Write the failing tests.**

```swift
@Test func builtInsAreConcertCorporateTheatreWithFixedIDs() {
    #expect(MarkerPreset.builtIn.map(\.name) == ["Concert", "Corporate", "Theatre"])
    #expect(MarkerPreset.builtIn.map(\.id) == MarkerPreset.builtIn.map(\.id))   // stable across reads
    #expect(Set(MarkerPreset.builtIn.map(\.id)).count == 3)
}
@Test func builtInListsHaveNoDuplicates() {
    for preset in MarkerPreset.builtIn {
        let names = preset.markers.labels.map { "\($0.category)|\($0.name.lowercased())" }
        #expect(Set(names).count == names.count, "\(preset.name) label names")
        for label in preset.markers.labels {
            #expect(Set(label.phrases.map { $0.lowercased() }).count == label.phrases.count, "\(preset.name) \(label.name)")
        }
        #expect(Set(preset.markers.departments.map { $0.lowercased() }).count == preset.markers.departments.count)
    }
}
@Test func builtInsRoundTrip() throws {
    for preset in MarkerPreset.builtIn {
        let decoded = try WilcoJSON.decoder().decode(MarkerSettings.self, from: WilcoJSON.encoder().encode(preset.markers))
        #expect(decoded == preset.markers)
    }
}
@Test func concertHearsTalkbackAndTheatreHearsItsCalls() {
    let concert = MarkerPreset.builtIn[0].markers, corporate = MarkerPreset.builtIn[1].markers, theatre = MarkerPreset.builtIn[2].markers
    func names(_ text: String, _ s: MarkerSettings) -> [String] { MarkerDetector.detect(in: text, settings: s).map(\.label) }
    #expect(names("Can I get more vocal in my wedge", concert) == ["Monitor request"])
    #expect(names("Changeover, ten minutes", concert) == ["Changeover"])
    #expect(names("Ladies and gentlemen, this is your half", theatre) == ["Half"])
    #expect(names("Warning LX 47", theatre) == ["Warning"])
    #expect(names("Standby VT 2", corporate).contains("Standby"))
    #expect(names("Intermission", concert) == [])        // removed from Concert
    #expect(names("Going into the next song", corporate) == [])   // song start off
}
```

- [ ] **Step 2: Run** `swift test --filter BuiltInPresetTests`. Expected: a compile failure.
- [ ] **Step 3: Implement.**
  - A private helper `standard(adding: [MarkerLabel], removing: Set<String>, departments: [String])` returns `.standard` with the named phase labels removed. It inserts each new label just after the last existing label of its category, or at the end, and appends the departments.
  - The lists are exactly as in the spec.
  - For Corporate, set `songStartEnabled = false`.
  - Each label in a built-in gets its own new UUID when the static is first built. Labels need stable IDs only within one run of the app.
- [ ] **Step 4: Run all package tests.** Expected: pass.
- [ ] **Step 5: Commit** with "Built-in Concert, Corporate and Theatre marker presets".

### Task 3: Built-in heading in the Presets menu, and docs

**Files:** Modify `Wilco/Settings/MarkerPresetsMenu.swift` and `docs/SPEC.md` §8.

- [ ] **Step 1: Update the menu.** After the user presets, add a `Section("Built-in")` with one button per `MarkerPreset.builtIn` entry, each going through the same `choose(_:)` as user presets.
  - `load(_:)` reads the file only for user presets. A built-in is loaded from its value. Tell the two apart with `MarkerPreset.builtIn.contains { $0.id == preset.id }`.
  - With no user presets, the "No Presets" placeholder becomes "No Saved Presets".
- [ ] **Step 2: Update SPEC §8.**
  - The Talkback category: purple, matched like other phrase labels, and empty in `.standard`.
  - "<department> <number> go".
  - The built-in presets: read-only, in code, made from `.standard` plus changes.
- [ ] **Step 3: Check.** Build the app and run the package tests. Expected: both pass.
- [ ] **Step 4: Commit** with "Presets menu lists built-in presets; spec".
