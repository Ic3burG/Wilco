# Wilco

[![CI](https://github.com/Ic3burG/Wilco/actions/workflows/ci.yml/badge.svg)](https://github.com/Ic3burG/Wilco/actions/workflows/ci.yml)

Live comms transcription for show control on macOS. Wilco captures every
channel of a multichannel audio interface (Dante, MADI, USB), transcribes each
one on-device, and fires OSC, MIDI, webhook and notification actions when
phrases like "Standby" or "Go" are heard on comms. After the show it builds a
post-show report of every call.

## Status

The core app works and is in testing; it is not yet released. See
[`docs/PROGRESS.md`](docs/PROGRESS.md) for the session-by-session log.

| Working | Still to rebuild |
|---|---|
| Show editor; import and export of `.wilco` shows | Peer sharing between Macs (`_wilco._tcp`) |
| Multichannel, multi-device capture with meters and auto-recovery | MCP server |
| On-device transcription (Apple speech on macOS 26+, Whisper) | MOS |
| Automation: OSC, MIDI, webhooks, notifications, cue markers | Automatic updates (Sparkle) |
| Post-show report with HTML, SRT and VTT export | Vor preset |
| Look & Feel, including Light / Dark / Match System | |
| Configurations: saved show setups, load in one click, import/export (new) | |

## Files

- Shows are `.wilco` files (JSON, `formatVersion` 1) and transcripts are
  `.jsonl`, one line per finalised segment. Both live in
  `~/Library/Application Support/Wilco` along with downloaded Whisper models.
- New show fields always get defaults, so older files keep opening.

## Building

Requires macOS 15 or later and Xcode 26 or later.

- **App:** open `Wilco.xcodeproj` and run the **Wilco** scheme. Set your own
  team under *Signing & Capabilities* if you are not building as the
  maintainer.
- **Tests:** `cd Packages/WilcoCore && swift test`. Tests that need a real
  show or real transcripts skip themselves when that data isn't present;
  `WILCO_ASR_TESTS=1 swift test` also runs real speech recognition.

## Layout

| Path | Contents |
|---|---|
| `Wilco/` | The SwiftUI app |
| `Packages/WilcoCore` | Model, audio capture, transcription and control, each its own target with tests |
| `Config/` | Info.plist and entitlements |
| `docs/SPEC.md` | Data formats, protocols, UI and known bugs |
| `docs/PROGRESS.md` | Work log, updated at the end of every session |
