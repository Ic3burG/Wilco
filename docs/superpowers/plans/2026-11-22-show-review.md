# Show Review Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Review tab in the report window that lists what went wrong in a session, with evidence and one-click fixes to the open show, vocabulary suggestions and a trend table.

**Architecture:** All analysis is pure WilcoCore code in `Report/Review/`: session stats → findings with fixes → suggestions → history. The app adds one tab and applies fixes by setting `AppModel.document`.

**Tech Stack:** Swift 6 (strict concurrency), SwiftUI, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-11-22-show-review-design.md`

## Global Constraints

- Deployment target macOS 15; CI builds with Xcode 26.6. Nothing here needs newer APIs.
- No change to `.jsonl` or `.wilco` formats. Nothing new is saved in the show.
- Nothing is changed in the show without a click. Nothing runs during capture.
- Don't name the reference app anywhere. No crew names or transcript quotes in committed docs or fixtures beyond the existing redacted fixtures.
- Tests use Swift Testing. Tests that read real sessions gate on `DataLocations.transcripts` existing.
- Copy uses plain words: "Mute channel", "Keep highlights off Band TB", "Add 2 to vocabulary", "Dismiss", "Show lines".

## Review Focus

1. **Session with no show copy whose channels aren't in the open show:** every fix is disabled with "Open the show this session was recorded with". Nothing crashes. Test in Task 2.
2. **Tiny or empty sessions (1–20 lines):** no findings except show setup; no division by zero in shares or percentiles. Test in Task 3.
3. **Lines with `confidence == nil`:** left out of confidence stats, never counted as unclear. Test in Task 1.
4. **Applying a fix twice, or after the user did it by hand:** shows as done; applying again leaves the show unchanged. Test in Task 2.
5. **Highlight that already lists specific channels:** "keep off" removes only that channel. A highlight with an empty list (all channels) becomes every channel but that one. Test in Task 2.

---

### Task 1: Session stats

**Files:**
- Create: `Packages/WilcoCore/Sources/WilcoCore/Report/Review/SessionStats.swift`
- Test: `Packages/WilcoCore/Tests/WilcoCoreTests/ReviewTests.swift` (suite "Session stats")

**Interfaces:**
- Produces:
  - `public struct SessionStats: Sendable` with:
    - `lines: Int`, `duration: Double`, `delayP90: Double?`, `fillerShare: Double`, `unclearShare: Double`
    - `channels: [UUID: ChannelStats]`
    - `static func make(_ segments: [TranscriptSegment]) -> SessionStats`
  - `public struct ChannelStats: Sendable` with:
    - `lines`, `fillers`, `capped` (Int)
    - `medianConfidence: Double?`
    - `delays: [Double]`, `delayP90: Double?`
  - `static let fillerWords: Set<String>` = yeah yep yes uh um mm mm-hmm hmm okay ok oh hey copy whoa right good so and no
  - `static func delay(of: TranscriptSegment, sessionStart: Double) -> Double`

Rules:
- Session start (seconds since 1970) is the minimum of `timestamp − sessionOffset` over all lines.
- A line's delay is `timestamp − sessionStart − sessionOffset`.
- `capped` counts delay ≥ 19 s.
- A filler is ≤2 words that are all filler words, or a single word under 0.5 confidence.
- Words are lowercased runs of `[a-z'-]`.

- [ ] **Step 1: Write failing tests**
  - `delayIsTimestampMinusStartAndOffset`: lines at offsets 10 and 20 written 1 s and 4 s after them → delays [1, 4] (the 1 s line defines the start).
  - `fillersCountOneWordAndUnclearSingles`: "Yeah." filler; "Copy that." filler; "Go." at 0.3 filler; "Standby lasers." not.
  - `nilConfidenceIsNotUnclear`: two lines with nil confidence → `unclearShare == 0`, `medianConfidence == nil`.
  - `emptySessionHasZeroShares`: `make([])` → lines 0, shares 0, `delayP90 == nil`.
- [ ] **Step 2:** `cd Packages/WilcoCore && swift test --filter "Session stats"`. Expect a compile failure (no `SessionStats`).
- [ ] **Step 3:** Implement `SessionStats.make`. p90 is the value at index `Int(0.9 * count)`, clamped.
- [ ] **Step 4:** Run again; expect PASS.
- [ ] **Step 5:** Commit "Review: session stats".

### Task 2: Show fixes

**Files:**
- Create: `Packages/WilcoCore/Sources/WilcoCore/Report/Review/ShowFix.swift`
- Test: `ReviewTests.swift` (suite "Show fixes")

**Interfaces:**
- Produces:
  - `public enum ShowFix: Hashable, Sendable` with cases:
    - `muteChannel(UUID)`
    - `keepHighlight(UUID, offChannel: UUID)`
    - `removePhrase(String, fromHighlight: UUID)`
    - `addVocabulary([String])`
    - `useRuleNameAsTitle(rule: UUID)`
  - `extension ShowDocument`:
    - `func canApply(_ fix: ShowFix) -> Bool`: every ID it names exists here.
    - `func isApplied(_ fix: ShowFix) -> Bool`
    - `func applying(_ fix: ShowFix) -> ShowDocument`: unchanged when `!canApply`.

Behaviour:
- `keepHighlight`: an empty `channelIDs` becomes all show channels minus that one; otherwise remove that one.
- `removePhrase` drops that phrase (case-insensitive) from the highlight's phrases.
- `addVocabulary` appends terms not already in `globalVocabulary` (case-insensitive).
- `useRuleNameAsTitle` sets the title of every `.notify` action on that rule to `"{rule}"`. It is applied when no notify title equals a leftover. Leftovers: `"New Rule"` (exact), or empty.

- [ ] **Step 1: Write failing tests**
  - `muteAppliesOnceAndReportsDone`
  - `removePhraseIgnoresCase`
  - `keepHighlightOffChannelFromAllChannels` (Review Focus 5)
  - `keepHighlightOffChannelFromAList` (Review Focus 5)
  - `addVocabularySkipsKnownTermsIgnoringCase`
  - `useRuleNameAsTitleReplacesNewRule`
  - `fixForMissingChannelCannotApplyAndChangesNothing` (Review Focus 1)
  - `applyingTwiceIsUnchanged` (Review Focus 4)
- [ ] **Step 2:** `swift test --filter "Show fixes"`. Expect a compile failure.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run; expect PASS.
- [ ] **Step 5:** Commit "Review: show fixes".

### Task 3: Findings

**Files:**
- Create: `Packages/WilcoCore/Sources/WilcoCore/Report/Review/ShowReview.swift`
- Test: `ReviewTests.swift` (suite "Show review")

**Interfaces:**
- Consumes: `SessionStats`, `ChannelStats`, `ShowFix`.
- Produces:
  - `public struct ShowReview: Sendable { var stats: SessionStats; var findings: [Finding] }`
  - `public struct Finding: Identifiable, Sendable` with:
    - `id: String`: stable key, e.g. `"busy:<channelUUID>"`
    - `severity: Severity` (`.problem`, `.warning`, `.info`)
    - `title: String`, `detail: String`
    - `channelID: UUID?`
    - `evidence: [UUID]`: up to 3 line IDs
    - `fixes: [FindingFix]`
  - `public struct FindingFix: Hashable, Sendable { var fix: ShowFix; var label: String }`
  - `public static func make(segments: [TranscriptSegment], show: ShowDocument) -> ShowReview`. Task 5 adds a `history:` parameter.
  - `public enum ReviewThresholds`, with the static constants below, in one place.

Checks:

| Check | Fires when | Fixes, in order |
|---|---|---|
| busy | ≥300 lines and ≥25% of the session's lines | `keepHighlight` for each enabled highlight with ≥10 hits on it; `muteChannel` |
| unclear | ≥30 lines and medianConfidence < 0.8 | none (detail points to vocabulary suggestions) |
| quiet | session ≥ 2 h, channel lines/hour < 4, and the session averages ≥ 200 lines/hour | none |
| cut | capped ≥ 10 across the session | none |
| behind | delay p90 of the last third − first third ≥ 5 s (thirds with ≥50 lines) | none |
| commonPhrase | a highlight or rule phrase with ≥10 hits an hour (from each line's `highlights` / `matchedKeywords`) | `removePhrase` for a highlight; none for a rule (the detail names it) |
| setup | a rule with a notify action whose title is a leftover | `useRuleNameAsTitle` |

- No music or chatter check in stage 1 (see the spec's calls): text signals didn't separate those channels on real data.
- Severity: setup `.problem`; busy, unclear and commonPhrase `.warning`; the rest `.info`.
- Order: severity, then lines descending.
- Detail copy states the numbers, e.g. "1,403 lines (30% of the session); its highlights hit 30 times."
- Evidence: the most repeated lines (busy), the lowest-confidence lines (unclear), example hits (commonPhrase).

- [ ] **Step 1: Write failing tests**, each on generated segments:
  - `busyChannelIsFoundWithMuteFix`
  - `quietChannelNeedsABusySession`
  - `leftoverNotificationTitleIsAProblem`
  - `commonHighlightPhraseOffersRemoval`
  - `tinySessionHasOnlySetupFindings` (Review Focus 2: 15 lines, a leftover title → exactly 1 finding)
  - `findingIDsAreStable`
- [ ] **Step 2:** Run `--filter "Show review"`; expect a compile failure.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run; expect PASS.
- [ ] **Step 5:** Commit "Review: findings".

### Task 4: Vocabulary suggestions

**Files:**
- Create: `Packages/WilcoCore/Sources/WilcoCore/Report/Review/VocabularySuggestions.swift`
- Modify: `ShowReview.swift` (add the finding)
- Test: `ReviewTests.swift` (suite "Vocabulary suggestions")

**Interfaces:**
- Produces:
  - `public struct NameCounts: Sendable { var counts: [String: Int] }`, with:
    - `static func make(_ segments: [TranscriptSegment]) -> NameCounts`
    - `mutating func add(_ other: NameCounts)`
  - `public struct VocabularySuggestion: Sendable, Hashable { var term: String; var heardAs: String?; var count: Int }`
  - `public static func suggest(counts: NameCounts, show: ShowDocument, minimum: Int = 3) -> [VocabularySuggestion]` (on `enum VocabularySuggestions`)

Rules:
- Names are capitalised words, or runs of 2 capitalised words, that are not the line's first word and not in `ShowReport.stopWords` (make it `package`/internal-visible, same module). All-caps tokens of 2–5 letters count too (NPC).
- Near-misses: for each channel name and vocabulary term T, any counted phrase P with the same word count, P ≠ T, and edit distance between their letters-only lowercase forms ≤ 2 and < half of T's length. Suggest T with `heardAs: P`, counted by P's count, when T itself was counted fewer times than P. Near-misses come first, then plain names by count. Drop terms already in vocabulary or rule/highlight phrases (case-insensitive). Max 8.
- Finding: id `"vocabulary"`, `.info`, fix `.addVocabulary`. Its label is "Add N to vocabulary", covering near-misses only. Plain names are listed as checkable rows. The UI rebuilds the fix from the ticked rows (Task 6).

- [ ] **Step 1: Write failing tests**
  - `channelNameHeardWrongIsSuggested`: channel "Tea Time", lines say "Omar on T Time." ×3 → `[term "Tea Time", heardAs "T Time", count 3]`, first.
  - `sentenceStartIsNotAName`
  - `knownTermsAreNotSuggested`
  - `acronymsCount`: "NPC is open." ×3, with NPC mid-line in at least one.
- [ ] **Step 2:** Run; expect a compile failure.
- [ ] **Step 3:** Implement. Edit distance is plain Levenshtein on arrays of Character.
- [ ] **Step 4:** Run; expect PASS.
- [ ] **Step 5:** Commit "Review: vocabulary suggestions".

### Task 5: History and trends

**Files:**
- Create: `Packages/WilcoCore/Sources/WilcoCore/Report/Review/SessionHistory.swift`
- Test: `ReviewTests.swift` (suite "Session history")

**Interfaces:**
- Produces:
  - `public struct SessionSummary: Sendable, Identifiable` with:
    - `id: URL`, `started: Date`, `showName: String`, `lines: Int`
    - `fillerShare`, `unclearShare` (Double)
    - `delayP90: Double?`
    - `names: NameCounts`
  - `public enum SessionHistory` with:
    - `static func summary(transcript: URL, candidates: [ShowDocument]) throws -> SessionSummary`. The show is the session copy, else `SessionShow.bestMatch`, else "Unknown show".
    - `static func sameShow(as name: String, in all: [SessionSummary], excluding: URL) -> [SessionSummary]`, newest first.
  - `ShowReview.make` uses `history` to:
    - fill `ShowReview.trend: [SessionSummary]`: this session plus the last 4.
    - add each summary's `names` into the counts before suggesting.

- [ ] **Step 1: Write failing tests**, writing temp `.jsonl` (+ `.wilco`) files:
  - `summaryUsesTheSessionCopyName`
  - `sameShowFiltersByNameNewestFirst`
  - `historyNamesFeedSuggestions`: a name seen once now and twice before is suggested.
- [ ] **Step 2:** Run; expect a failure.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run; expect PASS.
- [ ] **Step 5:** Commit "Review: session history and trends".

### Task 6: Tune on real sessions

**Files:**
- Test: `ReviewTests.swift` (suite "Review on real sessions", gated `.enabled(if: FileManager.default.fileExists(atPath: DataLocations.transcripts.path))`)

- [ ] **Step 1:** Add the test `everySessionReviewsWithoutNoise`.
  - It builds a review for every saved session with its history and prints each finding's id and title.
  - It asserts that no session has more than 8 findings.
  - It asserts that `Session 2026-11-21 1720-52` (if present) includes busy Band TB, the common phrase "hear", quiet Automation and the "Tea Time" suggestion. Match these by channel name, inside the test only.
- [ ] **Step 2:** Run `swift test --filter "Review on real sessions"` and read the printout. Adjust `ReviewThresholds` until the printout looks right to a human. Record the final values in the spec's check table.
- [ ] **Step 3:** Commit "Review: thresholds tuned on saved sessions".

### Task 7: Review tab

**Files:**
- Modify: `Wilco/Report/ReportModel.swift`:
  - add `Tab.review = "Review"`
  - add `review: ShowReview?` and `history: [SessionSummary]`
  - add `dismissed: Set<String>` (UserDefaults `review.dismissed`)
- Modify: `Wilco/Report/ShowReportWindow.swift`: add `case .review: ReviewView(model:app:)` to the tab switch.
- Create: `Wilco/Report/ReviewView.swift`

Behaviour:
- History loads once, detached, when the Review tab is first shown. The review is rebuilt when the session or history changes.
- Each finding is a card: severity dot, title, detail, fix buttons, "Show lines", "Dismiss".
- A fix button is:
  - disabled with the help text "Open the show this session was recorded with" when `!app.document.canApply(fix)`;
  - "✓ Done" when `isApplied`;
  - otherwise it runs `app.document = app.document.applying(fix); model.show = app.document`.
- "Show lines" sets `channelFilter = [channelID]`, `tab = .log` and `focusedMessage = evidence.first`.
- The vocabulary card has a toggle per suggestion; near-misses start on. Its button adds the ticked terms.
- Dismissed cards are hidden, with "Show N dismissed" at the bottom.
- The trend table sits under the cards: session start, lines, fillers %, unclear %, delay p90.
- Visible buttons only, no hover menus; leave the title bar alone.

- [ ] **Step 1:** Implement.
- [ ] **Step 2:** Build with the CLAUDE.md `xcodebuild` command. Expect `BUILD SUCCEEDED` and no warnings.
- [ ] **Step 3:** Run the app, open the report, select the 2026-11-21 1720 session, Review tab. Check the cards match Task 6's printout. Ask the user to try it before calling it verified.
- [ ] **Step 4:** Commit "Report: Review tab".

### Task 8: Docs

- [ ] Add a "Review tab" subsection to `docs/SPEC.md` §8 with the check table, the final thresholds and the fix rules.
- [ ] At session end: add a dated `docs/PROGRESS.md` section and update the README status table. Then commit, merge `show-review-fixes` into `main` and push.
