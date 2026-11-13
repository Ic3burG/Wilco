# CLAUDE.md

Wilco is a macOS app for live comms transcription in show control. It is a
clean rebuild of a reference app that shipped only as a compiled binary. Read these before starting work:

- `docs/SPEC.md`: what the app does (screens, file formats, OSC/MIDI/HTTP
  messages, the `_wilco._tcp` peer protocol, known bugs). It is the source of
  truth for behaviour.
- `docs/PROGRESS.md`: the session log. Its last "Next steps" section says
  where we stopped.

## Build and test

- **Package tests** (most logic lives here):
  `cd Packages/WilcoCore && swift test`
- **Real speech recognition tests:** `WILCO_ASR_TESTS=1 swift test`. These
  are slow and need speech models installed.
- **App build** (the same command CI runs, unsigned):
  `xcodebuild build -project Wilco.xcodeproj -scheme Wilco -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY=""`
- Tests use Swift Testing (`@Suite`, `@Test`), not XCTest. Tests that need
  local-only data gate themselves with `.enabled(if:)`: the user's real show,
  real session transcripts (`DataLocations.transcripts`) or `WILCO_ASR_TESTS`. On
  CI they skip quietly, so a green CI run doesn't prove those tests passed.
  Run them locally when touching formats, reports or transcription.
- `WILCO_EXPORT_DIR=<folder>` makes the live-session report test write its
  HTML/SRT/VTT exports there so you can look at them.

## Layout

| Path | Contents |
|---|---|
| `Wilco/` | SwiftUI app: windows, inspector, settings, `AppModel`, controllers |
| `Packages/WilcoCore/Sources/WilcoCore` | Platform-free model, persistence, automation matching, report, segmenter |
| `Packages/WilcoCore/Sources/WilcoAudio` | CoreAudio HAL capture, devices, multi-device |
| `Packages/WilcoCore/Sources/WilcoTranscription` | Apple speech (macOS 26+) and WhisperKit transcribers, language catalog, model assets |
| `Packages/WilcoCore/Sources/WilcoControl` | OSC (UDP/TCP/SLIP) and MIDI output |
| `Packages/WilcoCore/Tests/WilcoCoreTests/Fixtures` | Real show and `.jsonl` files (identifying text replaced) for format tests |
| `Config/` | Info.plist and entitlements |
| `reference/` | Local-only evidence from the reference app (see below) |

Put testable logic in the package and keep the app target thin. New logic
gets tests. A bug fix gets a regression test.

## Rules

- **Keep files opening.** Existing `.wilco` shows, `.jsonl` transcripts,
  Whisper model folders and preferences must keep opening. New fields in a
  show need defaults so older files still decode.
- **Don't name or version the reference app.** No name, identifiers or
  version number for it anywhere in the project: code, comments, docs and
  commit messages. Say "the reference app" in docs; in code comments, explain
  the behaviour without pointing at another app.
- **`reference/` stays private.** It holds the original binary, the user's
  real show and crash logs, and is gitignored apart from its README. Never
  commit its contents or quote personal data from it in public docs or commit
  messages. Analyse `reference/reference-app.app`, never the
  installed copy in `/Applications`.
- **Rebuild from the spec; don't port decompiled code.** Use REA/Ghidra
  output to learn behaviour, then write fresh Swift.
- **CI runs an older Xcode than this Mac** (CI 26.6, local 27.2). Guard
  anything that needs the Xcode 27 / macOS 27 SDK, or CI will fail. Apple's
  speech APIs need `@available(macOS 26, *)`; the deployment target is
  macOS 15.
- **The audio thread is real-time.** Don't allocate, lock or log in capture
  callbacks. Validate inputs such as device channel indexes before capture
  starts, not inside the callback.
- **Strings from speech are untrusted.** Sanitise transcript text before it
  goes into OSC addresses, URLs or templates.
- Swift 6 language mode with strict concurrency. Fix warnings; don't silence
  them.

## Testing in the app

- Quit the reference app first; it shares the audio input and speech
  hardware.
- In `PROGRESS.md`, "verified" means the user tried it in the app on a real
  Mac and "tested" means automated tests only. Don't call something verified
  until the user confirms it.

## End of session

Add a dated section to the end of `docs/PROGRESS.md` (features, fixes,
tooling, next steps / where we left off) in the same plain style, update the
README's status table if it changed, then commit and push to `main`.
